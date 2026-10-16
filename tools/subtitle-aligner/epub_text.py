#!/usr/bin/env python3
"""Extract reviewable UTF-8 text sections from a DRM-free EPUB in its spine order."""
import argparse
import hashlib
import json
from pathlib import Path
import posixpath
import re
import unicodedata
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
import zipfile

EPUB_TYPE = "{http://www.idpf.org/2007/ops}type"
BLOCKS = {"p", "div", "section", "article", "blockquote", "li", "dt", "dd", "tr", "h1", "h2", "h3", "h4", "h5", "h6"}
NOTES = {"noteref", "footnote", "endnote", "footnotes", "endnotes", "pagebreak"}


def local_name(element):
    return element.tag.rsplit("}", 1)[-1] if isinstance(element.tag, str) else ""


def archive_path(base, href):
    parsed = urlsplit(href)
    if parsed.scheme or parsed.netloc or parsed.query:
        raise ValueError(f"Non-local EPUB reference: {href!r}")
    path = posixpath.normpath(posixpath.join(posixpath.dirname(base), unquote(parsed.path)))
    if path.startswith(("/", "../")) or path in (".", "..") or "\\" in path or "\x00" in path:
        raise ValueError(f"Unsafe EPUB path: {href!r}")
    return path


def read_xml(archive, path):
    info = archive.getinfo(path)
    if info.file_size > 10_000_000 or info.flag_bits & 1:
        raise ValueError(f"EPUB document is encrypted or too large: {path}")
    data = archive.read(info)
    if b"<!ENTITY" in data.upper():
        raise ValueError(f"Custom XML entities are unsupported: {path}")
    return ET.fromstring(data)


def omitted(element, profile):
    tag = local_name(element)
    semantic = set(element.get(EPUB_TYPE, "").split())
    role = element.get("role", "")
    if tag in {"script", "style", "nav", "rt", "rp"} or semantic & NOTES:
        return True
    if role in {"doc-noteref", "doc-footnote", "doc-endnote", "doc-pagebreak"}:
        return True
    if "hidden" in element.attrib or element.get("aria-hidden") == "true":
        return True
    if profile == "wolne-lektury" and "fundraising" in element.get("class", "").split():
        return True
    if profile == "wolne-lektury" and tag == "a":
        return "annotations.xhtml#" in element.get("href", "")
    return False


def plain_text(element, profile):
    if omitted(element, profile):
        return ""
    tag = local_name(element)
    if tag in {"br", "hr"}:
        return "\n"
    parts = [element.text or ""]
    for child in element:
        parts.append(plain_text(child, profile))
        parts.append(child.tail or "")
    value = "".join(parts)
    return f"\n\n{value}\n\n" if tag in BLOCKS else value


def clean_paragraphs(text):
    text = unicodedata.normalize("NFC", text).replace("\u00ad", "").replace("\ufeff", "")
    return "\n\n".join(" ".join(line.split()) for line in re.split(r"\n\s*\n", text) if line.strip())


def extract(path, profile="generic"):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) > 5000 or len(names) != len(set(names)):
            raise ValueError("Too many or duplicate EPUB archive entries.")
        if sum(info.file_size for info in archive.infolist()) > 200_000_000:
            raise ValueError("EPUB expanded size exceeds 200 MB.")
        if archive.read("mimetype").strip() != b"application/epub+zip":
            raise ValueError("Not an EPUB archive.")
        container = read_xml(archive, "META-INF/container.xml")
        rootfile = container.find(".//{*}rootfile")
        if rootfile is None:
            raise ValueError("EPUB container has no package rootfile.")
        package_path = archive_path("", rootfile.attrib["full-path"])
        package = read_xml(archive, package_path)
        manifest = package.find("{*}manifest")
        spine = package.find("{*}spine")
        if manifest is None or spine is None:
            raise ValueError("EPUB requires a manifest and spine.")
        items = {item.attrib["id"]: item for item in manifest}
        if len(items) != len(manifest):
            raise ValueError("Duplicate manifest IDs.")
        metadata = package.find("{*}metadata")
        title = metadata.findtext("{*}title", "") if metadata is not None else ""
        language = metadata.findtext("{*}language", "") if metadata is not None else ""
        creators = [item.text for item in metadata.findall("{*}creator")] if metadata is not None else []
        sections, skipped = [], []
        for reference in spine:
            identifier = reference.attrib["idref"]
            if identifier not in items:
                raise ValueError(f"Missing spine item: {identifier}")
            item = items[identifier]
            href = archive_path(package_path, item.attrib["href"])
            if reference.get("linear") == "no" or "nav" in item.get("properties", "").split():
                skipped.append({"href": href, "reason": "non-linear or navigation"})
                continue
            if item.get("media-type") != "application/xhtml+xml":
                raise ValueError(f"Unsupported spine document: {href}")
            if profile == "wolne-lektury" and posixpath.basename(href) in {
                "title.xhtml", "annotations.xhtml", "support.xhtml", "last.xhtml"
            }:
                skipped.append({"href": href, "reason": "Wolne Lektury front/back matter"})
                continue
            document = read_xml(archive, href)
            body = document.find("{*}body")
            if body is None:
                raise ValueError(f"EPUB document has no body: {href}")
            if profile == "wolne-lektury":
                body = next((node for node in body.iter() if node.get("id") == "book-text"), None)
                if body is None:
                    skipped.append({"href": href, "reason": "outside Wolne Lektury book-text"})
                    continue
            text = clean_paragraphs(plain_text(body, profile))
            if not text:
                skipped.append({"href": href, "reason": "empty after cleanup"})
                continue
            headings = [clean_paragraphs(plain_text(node, profile)) for node in body.iter()
                        if local_name(node) in {"h1", "h2", "h3", "h4", "h5", "h6"}]
            sections.append({"href": href, "headings": headings, "text": text,
                             "word_count": len(text.split())})
        if not sections:
            raise ValueError("EPUB has no extractable reading text.")
        return {"title": title, "language": language, "creators": creators, "profile": profile,
                "epub_sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest(),
                "sections": sections, "skipped": skipped}


def write_extraction(result, output):
    output.mkdir(parents=True, exist_ok=False)
    (output / "sections").mkdir()
    index = {key: value for key, value in result.items() if key != "sections"}
    index["sections"] = []
    for number, section in enumerate(result["sections"], 1):
        name = f"sections/{number:03}.txt"
        (output / name).write_text(section["text"] + "\n", encoding="utf-8")
        index["sections"].append({key: value for key, value in section.items() if key != "text"} | {"file": name})
    (output / "transcript.txt").write_text("\n\n".join(s["text"] for s in result["sections"]) + "\n", encoding="utf-8")
    (output / "epub-index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epub", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=["generic", "wolne-lektury"], default="generic")
    args = parser.parse_args(argv)
    try:
        result = extract(args.epub, args.profile)
        write_extraction(result, args.output)
    except (OSError, ValueError, KeyError, ET.ParseError, zipfile.BadZipFile) as error:
        parser.exit(1, f"error: {error}\n")
    print(f"Extracted {len(result['sections'])} spine sections; review {args.output / 'epub-index.json'} before matching audio.")


if __name__ == "__main__":
    main()
