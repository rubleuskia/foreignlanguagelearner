#!/usr/bin/env python3
"""Extract source evidence, build validated exam imports, and preview them locally."""
from __future__ import annotations

import argparse
import copy
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
from pathlib import Path
import re
import shutil
import tempfile
import unicodedata
from urllib.parse import unquote, urlsplit

from ai_assessment import is_assessment_task, build_grading_request, compile_assessment, InvalidAssessment
from backend.exams.token_membership import normalize_token, tokens as membership_tokens, validate_membership

HERE = Path(__file__).resolve().parent
ARCHIVE_URL = "https://certyfikatpolski.pl/o-egzaminie/testy-egzaminacyjne-z-poprzednich-lat/"
VERSION = "exam-digitizer/1.1"
ROLES = {"exam_paper": "paper", "transcript_and_answer_keys": "keys", "audio": "audio"}


class InvalidExam(ValueError):
    pass


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def canonical_digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                     separators=(",", ":")).encode()).hexdigest()


def inside(root, relative):
    root = Path(root).resolve()
    path = (root / relative).resolve()
    if path == root or not path.is_relative_to(root):
        raise InvalidExam(f"Path must stay inside {root}: {relative}")
    return path


def select_sources(root, selection):
    root = Path(root).resolve()
    manifest = read_json(root / "manifest.json")
    entries = [e for e in manifest["entries"] if str(e.get("year")) == str(selection["year"])
               and all(e.get(k) == selection[k] for k in ("session", "level"))]
    selected = {}
    for entry in entries:
        role = ROLES.get(entry.get("kind"))
        if not role or role in selected:
            raise InvalidExam("Expected exactly one paper, transcript/key PDF and audio")
        path = inside(root, entry["path"])
        if not path.is_file() or digest(path) != entry["sha256"] or path.stat().st_size != entry["bytes"]:
            raise InvalidExam(f"Source differs from download manifest: {path}")
        selected[role] = (entry, path)
    if set(selected) != {"paper", "keys", "audio"}:
        raise InvalidExam(f"Incomplete source selection: {selection}")
    return selected


def extract_evidence(selected, output, render=True):
    """Preserve physical-page evidence; do not pretend PDF text is a question parser."""
    from pypdf import PdfReader

    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    documents = []
    images = []
    for role, (entry, path) in selected.items():
        if role == "audio":
            continue
        reader = PdfReader(path)
        doc = {"source_id": role, "url": entry["url"], "sha256": entry["sha256"], "pages": []}
        rendered = None
        if render:
            import pymupdf
            rendered = pymupdf.open(path)
        for index, page in enumerate(reader.pages):
            text = page.extract_text(extraction_mode="layout") or ""
            row = {"page": index + 1, "width_pt": float(page.mediabox.width),
                   "height_pt": float(page.mediabox.height), "text": text,
                   "source_refs": [{"source_id": role, "page": index + 1}]}
            doc["pages"].append(row)
            if rendered is not None:
                relative = f"{role}/page-{index + 1:03}.png"
                target = output / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                rendered[index].get_pixmap(matrix=pymupdf.Matrix(1.5, 1.5), alpha=False).save(target)
                images.append({"path": f"evidence/{relative}", "sha256": digest(target),
                               "source_refs": row["source_refs"]})
        if rendered is not None:
            rendered.close()
        documents.append(doc)
    evidence = {"generator": VERSION, "source_archive": ARCHIVE_URL, "documents": documents}
    write_json(output / "extracted.json", evidence)
    write_json(output / "page-index.json", {"source_archive": ARCHIVE_URL, "pages": images})
    return documents


def descendants(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from descendants(child)
    elif isinstance(value, list):
        for child in value:
            yield from descendants(child)


def copy_review_images(content_review, stage):
    """Retain review-relative paths so paper/page-001 and keys/page-001 stay distinct."""
    stage = Path(stage).resolve()
    review_root = Path(content_review['rendered_evidence_directory']).resolve()
    for row in content_review.get('rendered_pages', []):
        source = inside(review_root, row['path'])
        if source.is_file() and digest(source) != row['sha256']:
            raise InvalidExam(f'Content-review evidence differs: {source}')
        if source.is_file():
            target = inside(stage / 'evidence/content-review', source.relative_to(review_root))
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists() and digest(target) != row['sha256']:
                raise InvalidExam(f'Content-review images collide: {target}')
            shutil.copy2(source, target)
            row['path'] = target.relative_to(stage).as_posix()
        else:
            ref = row['source_refs'][0]
            target = stage / 'evidence' / ref['source_id'] / f"page-{ref['page']:03}.png"
            row['original_review_image_sha256'] = row.pop('sha256')
            row['historical_image_name'] = row.pop('path')
            row['image_status'] = 'regenerated_from_original' if target.is_file() else 'see_original_pdf_page'
            if target.is_file():
                row.update(path=target.relative_to(stage).as_posix(), sha256=digest(target))


def validate_exam(exam, root=None):
    from jsonschema import Draft202012Validator, FormatChecker

    errors = sorted(Draft202012Validator(read_json(HERE / "exam.schema.json"),
                                         format_checker=FormatChecker()).iter_errors(exam),
                    key=lambda e: str(list(e.path)))
    if errors:
        raise InvalidExam("Schema: " + "; ".join(f"{list(e.path)}: {e.message}" for e in errors[:8]))
    sources = {source["id"]: source for source in exam["sources"]}
    if len(sources) != len(exam["sources"]):
        raise InvalidExam("Duplicate source ID")
    if set(sources) != {"paper", "keys", "audio"}:
        raise InvalidExam("Source IDs must be paper, keys, audio")
    for node in descendants(exam):
        for ref in node.get("source_refs", []):
            source = sources.get(ref["source_id"])
            if not source:
                raise InvalidExam(f"Unknown source reference: {ref}")
            if source["media_type"] == "application/pdf":
                if "page" not in ref or not 1 <= ref["page"] <= source["page_count"]:
                    raise InvalidExam(f"Invalid physical PDF page: {ref}")
    ids = set()
    for node in descendants(exam["sections"]):
        if "id" in node:
            if node["id"] in ids:
                raise InvalidExam(f"Duplicate content ID: {node['id']}")
            ids.add(node["id"])
    positions = [section["position"] for section in exam["sections"]]
    if len(positions) != len(set(positions)):
        raise InvalidExam("Repeated section position")
    available = {section["id"] for section in exam["sections"] if section.get("status") != "source_missing"}
    if not set(exam["interactive_section_ids"]).issubset(available):
        raise InvalidExam("Interactive modules must exist in the supplied originals")
    item_count = 0
    modes = {}
    for section in exam["sections"]:
        tasks = section["tasks"]
        positions = [task["position"] for task in tasks]
        if len(positions) != len(set(positions)):
            raise InvalidExam(f"Repeated task position in {section['id']}")
        selection = section.get("selection")
        if section.get("status") == "source_missing":
            if tasks:
                raise InvalidExam("A source_missing section cannot contain invented tasks")
            continue
        if not tasks:
            raise InvalidExam(f"Empty section without source_missing: {section['id']}")
        if selection:
            if set(selection["task_ids"]) != {task["id"] for task in tasks}:
                raise InvalidExam("Selection must refer to all alternative task sets")
            if any(task["max_score_units"] != section["max_score_units"] for task in tasks):
                raise InvalidExam("Alternative sets must each match the section maximum")
        elif sum(task["max_score_units"] for task in tasks) != section["max_score_units"]:
            raise InvalidExam(f"Task totals differ from section maximum: {section['id']}")
        for task in tasks:
            if is_assessment_task(task) and not task.get("ai_assessment"):
                raise InvalidExam(f"Missing source-bound AI contract: {task['id']}")
            if task.get("ai_assessment") is not None:
                try:
                    compiled = compile_assessment(task, exam["id"])
                except InvalidAssessment as error:
                    raise InvalidExam(f"Invalid source-bound assessment: {error}") from None
                if task["ai_assessment"] != compiled:
                    raise InvalidExam(f"AI contract differs from official task material: {task['id']}")
            options = {option["id"] for option in task["options"]}
            display_codes = task.get("presentation", {}).get("display_codes", {})
            if display_codes:
                if not set(display_codes).issubset(options) or len(set(display_codes.values())) != len(display_codes):
                    raise InvalidExam(f"Invalid original-to-display code mapping: {task['id']}")
            items = task["items"]
            positions = [item["position"] for item in items]
            if len(positions) != len(set(positions)):
                raise InvalidExam(f"Repeated item position in {task['id']}")
            if not items:
                raise InvalidExam(f"Task has no answer fields: {task['id']}")
            if all(item["max_score_units"] is not None for item in items):
                if sum(item["max_score_units"] for item in items) != task["max_score_units"]:
                    raise InvalidExam(f"Item totals differ from task maximum: {task['id']}")
            elif any(item["grading"]["mode"] not in ("ai_stub", "manual") for item in items):
                raise InvalidExam("Shared task-level scoring is only allowed for AI/manual tasks")
            item_ids = {item["id"] for item in items}
            for block in task["blocks"]:
                for gap_id in re.findall(r"\{\{([^{}]+)\}\}", block["text"]):
                    if gap_id not in item_ids:
                        raise InvalidExam(f"Unknown gap {gap_id} in {task['id']}")
            for item in items:
                item_count += 1
                grading = item["grading"]
                mode = grading["mode"]
                modes[mode] = modes.get(mode, 0) + 1
                allowed = set(item.get("option_ids", []))
                if not allowed.issubset(options):
                    raise InvalidExam(f"Unknown option in {item['id']}")
                if item["response_type"] in ("single_choice", "multi_choice") and not allowed:
                    raise InvalidExam(f"Choice item needs options: {item['id']}")
                if mode in ("exact", "set", "token_membership") and not grading["accepted_answers"]:
                    raise InvalidExam(f"No verified accepted answer: {item['id']}")
                original_answers = grading.get("source_accepted_option_ids", [])
                if display_codes and original_answers:
                    if any(answer not in display_codes for answer in original_answers):
                        raise InvalidExam("Renumbered answer has no original option mapping")
                    if set(grading["accepted_answers"]) != {display_codes[answer] for answer in original_answers}:
                        raise InvalidExam("Renumbered key differs from the original answer")
                if item["max_score_units"] is None and mode in ("exact", "set", "token_membership"):
                    raise InvalidExam("Objective items require a maximum score")
                if mode == "token_membership":
                    try:
                        validate_membership(item)
                    except ValueError as error:
                        raise InvalidExam(str(error)) from None
                for accepted in grading["accepted_answers"]:
                    if mode == "set":
                        if not isinstance(accepted, list) or not set(accepted).issubset(allowed):
                            raise InvalidExam(f"Invalid accepted option set: {item['id']}")
                    elif mode == "exact":
                        if not isinstance(accepted, str):
                            raise InvalidExam(f"Exact answer must be a string: {item['id']}")
                        if allowed and accepted not in allowed:
                            raise InvalidExam(f"Accepted option not available: {item['id']}")
    if root:
        for source in sources.values():
            file = inside(root, source["path"])
            if not file.is_file() or file.stat().st_size != source["bytes"] or digest(file) != source["sha256"]:
                raise InvalidExam(f"Package source is missing or changed: {source['path']}")
        audio_path = Path(root) / "audio.json"
        material = {key: value for key, value in exam.items() if key != "revision"}
        expected = canonical_digest({"exam": material, "audio": read_json(audio_path) if audio_path.exists() else None})
        if expected != exam["revision"]:
            raise InvalidExam("Content revision differs from canonical exam/audio material")
    return {"section_count": len(exam["sections"]), "task_count": sum(len(s["tasks"]) for s in exam["sections"]),
            "item_count": item_count, "grading_modes": modes,
            "source_missing_sections": [s["id"] for s in exam["sections"] if s.get("status") == "source_missing"]}


def validate_audio(audio, exam):
    source = next(source for source in exam["sources"] if source["id"] == "audio")
    if audio.get("source", {}).get("sha256") != source["sha256"]:
        raise InvalidExam("Audio alignment does not match the original MP3 SHA-256")
    duration = audio["source"].get("duration_ms")
    if not isinstance(duration, int) or duration <= 0:
        raise InvalidExam("Audio duration must be positive integer milliseconds")
    expected = {t["label"] for s in exam["sections"] if s["id"] == "listening" for t in s["tasks"]}
    rows = audio.get("tasks", [])
    if {t["task_label"] for t in rows} != expected or len(rows) != len(expected):
        raise InvalidExam("Audio alignment must identify every listening task exactly once")
    intervals = []
    for task in rows:
        if not task.get("occurrences"):
            raise InvalidExam(f"Missing actual audio occurrences for task {task['task_label']}")
        for occurrence in task["occurrences"]:
            start, end = occurrence["start_ms"], occurrence["end_ms"]
            if type(start) is not int or type(end) is not int or not 0 <= start < end <= duration:
                raise InvalidExam("Invalid audio interval")
            intervals.append((start, end))
    intervals.sort()
    if any(a[1] > b[0] for a, b in zip(intervals, intervals[1:])):
        raise InvalidExam("Task playback intervals overlap")
    return {"task_count": len(rows), "occurrence_count": len(intervals), "duration_ms": duration,
            "review_status": audio.get("review_status", "see_audio_report"),
            "quality_summary": audio.get("report", {}).get("quality_summary", {})}


def source_rows(selected):
    from pypdf import PdfReader
    rows = []
    for role, (entry, path) in selected.items():
        row = {"id": role, "url": entry["url"], "path": f"sources/{path.name}",
               "sha256": entry["sha256"], "bytes": entry["bytes"],
               "media_type": "audio/mpeg" if role == "audio" else "application/pdf"}
        if role != "audio":
            row["page_count"] = len(PdfReader(path).pages)
        rows.append(row)
    return rows


def build(profile_path, sources_root, output, audio_path=None, render=True):
    output = Path(output).resolve()
    if output.exists():
        raise InvalidExam("Output already exists; choose a new directory to retain prior artifacts")
    profile = read_json(profile_path)
    if set(profile) & {"schema_version", "revision", "sources", "provenance"}:
        raise InvalidExam("Reviewed profiles must not contain generated package identity fields")
    selected = select_sources(sources_root, profile["source_selection"])
    rows = source_rows(selected)
    exam = copy.deepcopy(profile)
    exam.pop("source_selection")
    exam.update(schema_version="1.1", sources=rows,
                provenance={"profile_sha256": digest(profile_path), "archive_url": ARCHIVE_URL, "generator": VERSION})
    exam["interactive_section_ids"] = [s["id"] for s in exam["sections"] if s["id"] in ("listening", "reading", "grammar") and s.get("status") != "source_missing"]
    for section in exam["sections"]:
        for task in section["tasks"]:
            if is_assessment_task(task):
                task["ai_assessment"] = compile_assessment(task, exam["id"])
    audio = read_json(audio_path) if audio_path else None
    if audio:
        audio_source = next(row for row in rows if row["id"] == "audio")
        audio["source"].update(source_id="audio", path=audio_source["path"], url=audio_source["url"])
        if audio.get("reference_source"):
            key_source = next(row for row in rows if row["id"] == "keys")
            audio["reference_source"].update(path=key_source["path"], url=key_source["url"])
    exam["revision"] = canonical_digest({"exam": exam, "audio": audio})
    summary = validate_exam(exam)
    audio_summary = validate_audio(audio, exam) if audio else None
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{output.name}-", dir=output.parent))
    try:
        (stage / "sources").mkdir()
        for role, (_, source) in selected.items():
            shutil.copy2(source, stage / "sources" / source.name)
        documents = extract_evidence(selected, stage / "evidence", render)
        review_path = Path(profile_path).with_name(Path(profile_path).stem + ".content-review.json")
        content_review = None
        if review_path.is_file():
            content_review = read_json(review_path)
            copy_review_images(content_review, stage)
            content_review.update(original_review_sha256=digest(review_path),
                                  rendered_evidence_directory="evidence/content-review",
                                  full_page_index="evidence/page-index.json")
            for original in content_review.get("originals", []):
                row = next(row for row in rows if row["id"] == original["source_id"])
                if original["sha256"] != row["sha256"]:
                    raise InvalidExam("Content review refers to a different original")
                original.update(original_path=row["path"], url=row["url"])
            write_json(stage / "evidence" / "content-review.json", content_review)
        write_json(stage / "exam.json", exam)
        ai_tasks = [task for section in exam["sections"] for task in section["tasks"] if task.get("ai_assessment")]
        write_json(stage / "ai-assessment.json", {
            "schema_version": "1.0", "exam_id": exam["id"], "revision": exam["revision"],
            "source_refs": [{"source_id": row["id"], "url": row["url"], "sha256": row["sha256"]} for row in rows],
            "contracts": [task["ai_assessment"] for task in ai_tasks],
            "empty_answer_request_templates": [build_grading_request(exam, task["id"], {}) for task in ai_tasks],
            "network_requests_performed": False})
        shutil.copy2(profile_path, stage / "profile.json")
        shutil.copy2(HERE / "exam.schema.json", stage / "exam.schema.json")
        (stage / "web").mkdir()
        for name in ("index.html", "styles.css", "app.mjs", "logic.mjs"):
            shutil.copy2(HERE / "web" / name, stage / "web" / name)
        if audio:
            write_json(stage / "audio.json", audio)
            artifacts = Path(audio_path).parent / "evidence"
            if artifacts.is_dir():
                shutil.copytree(artifacts, stage / "alignment")
        quality = {"generator": VERSION, "exam_id": exam["id"], "revision": exam["revision"],
                   "status": "ready_for_local_simulation" if audio else "audio_alignment_missing",
                   "source_archive": ARCHIVE_URL, "source_refs": [{"source_id": row["id"], "url": row["url"], "sha256": row["sha256"]} for row in rows],
                   "structure": summary, "audio": audio_summary,
                   "ai_contracts": {"task_ids": [task["id"] for task in ai_tasks], "network_requests_performed": False},
                   "content_review": {"path": "evidence/content-review.json", "checks": content_review.get("visual_checks", [])} if content_review else None,
                   "pdf_pages": sum(len(doc["pages"]) for doc in documents),
                   "limits": ["AI grading is a stub; pending answers receive no invented score.",
                              "Audio acoustic/repetition quality is described in audio.json, not certified by positive timestamps.",
                              "Source-missing modules remain explicitly unavailable.",
                              "New exams require reviewed structure/key profiles after evidence extraction."]}
        write_json(stage / "quality-report.json", quality)
        plan_path = HERE.parent.parent / "docs" / "EXAM_IMPLEMENTATION_PLAN.md"
        if plan_path.is_file():
            shutil.copy2(plan_path, stage / "IMPLEMENTATION_PLAN.md")
        source_lines = "\n".join(f"- {row['id']}: {row['url']} (SHA-256 {row['sha256']})" for row in rows)
        (stage / "README.md").write_text(
            f"# {exam['title']}\n\n"
            f"Exam ID: `{exam['id']}`. Schema: 1.1. Revision: `{exam['revision']}`.\n\n"
            "Use `exam.json` and its source files for backend import. `exam.schema.json` and the utility's validate command check the package. "
            "`audio.json` describes actual occurrences; `alignment/` retains the measured evidence and review flags. "
            "`ai-assessment.json` contains grammar V/VI prompts and strict score/rationale output contracts; no inference was performed. "
            "Writing remains in JSON only; the prototype uses listening, reading and grammar.\n\n"
            "`artifact-manifest.json` links every other artifact to the originals and records its size/SHA-256. "
            "`quality-report.json` records verification and remaining review flags. "
            "`IMPLEMENTATION_PLAN.md` contains the planned native/backend integration.\n\n"
            f"## Original sources\n\n{source_lines}\n\n"
            "## Local preview\n\n"
            f"Run from the repository root:\n\n```sh\npython tools/exam-digitizer/exam_digitizer.py serve {output} --port 8773\n```\n\n"
            "Open http://127.0.0.1:8773/. Choose training or exam before starting.\n", encoding="utf-8")
        all_refs = [{"source_id": source["id"], "url": source["url"], "sha256": source["sha256"]} for source in rows]
        pages = {entry["path"]: entry["source_refs"] for entry in read_json(stage / "evidence" / "page-index.json")["pages"]}
        artifacts = []
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                relative = path.relative_to(stage).as_posix()
                artifacts.append({"path": relative, "sha256": digest(path), "bytes": path.stat().st_size,
                                  "source_refs": pages.get(relative, all_refs)})
        write_json(stage / "artifact-manifest.json", {"exam_id": exam["id"], "revision": exam["revision"],
                                                     "source_refs": all_refs, "artifacts": artifacts})
        validate_exam(exam, stage)
        stage.rename(output)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return quality


def normalized(value, ignore_case=False):
    result = unicodedata.normalize("NFC", value).strip()
    return result.casefold() if ignore_case else result


def grade_attempt(exam, request):
    """Deterministic objective grading plus explicit AI placeholders; no AI calls."""
    if request.get("revision") != exam["revision"]:
        raise InvalidExam("Attempt revision does not match this package")
    responses = request.get("responses", {})
    choices = request.get("selected_tasks", {})
    if not isinstance(responses, dict) or not isinstance(choices, dict):
        raise InvalidExam("responses and selected_tasks must be objects")
    active = [s for s in exam["sections"] if s["id"] in exam["interactive_section_ids"]]
    known = {i["id"] for s in active for t in s["tasks"] for i in t["items"]}
    if set(responses) - known:
        raise InvalidExam("Attempt contains unknown item IDs")
    result = []
    for section in active:
        if section.get("status") == "source_missing":
            result.append({"section_id": section["id"], "status": "source_missing", "score_units": None, "items": []})
            continue
        tasks = section["tasks"]
        if section.get("selection"):
            selected = choices.get(section["id"], [])
            if isinstance(selected, str):
                selected = [selected]
            if not isinstance(selected, list) or len(selected) != 1 or selected[0] not in section["selection"]["task_ids"]:
                result.append({"section_id": section["id"], "status": "selection_required", "score_units": None, "items": []})
                continue
            tasks = [task for task in tasks if task["id"] == selected[0]]
        rows = []
        for task in tasks:
            for item in task["items"]:
                answer = responses.get(item["id"])
                mode = item["grading"]["mode"]
                if answer is not None:
                    allowed = item.get("option_ids", [])
                    if item["response_type"] == "multi_choice":
                        if not isinstance(answer, list) or any(not isinstance(a, str) for a in answer) or len(answer) != len(set(answer)):
                            raise InvalidExam(f"Expected unique string choices: {item['id']}")
                        if any(v not in allowed for v in answer):
                            raise InvalidExam(f"Unknown selected option: {item['id']}")
                        limit = item.get("selection", {}).get("max")
                        if limit is not None and len(answer) > limit:
                            raise InvalidExam(f"Too many selected options: {item['id']}")
                    elif not isinstance(answer, str):
                        raise InvalidExam(f"Expected text/choice string: {item['id']}")
                    elif allowed and answer and answer not in allowed:
                        raise InvalidExam(f"Unknown selected option: {item['id']}")
                if mode in ("ai_stub", "manual"):
                    rows.append({"item_id": item["id"], "status": "pending_ai" if mode == "ai_stub" else "pending_manual",
                                 "awarded_score_units": None, "max_score_units": item["max_score_units"]})
                    continue
                if mode == "token_membership":
                    tokens = membership_tokens(answer or "", item["grading"])
                    accepted = {normalize_token(a,item["grading"]) for a in item["grading"]["accepted_answers"]}
                    if len(tokens) > item["grading"].get("max_tokens", len(accepted)):
                        raise InvalidExam(f"Too many token answers: {item['id']}")
                    matched = len(tokens & accepted)
                    score = matched * item["max_score_units"] // len(accepted)
                    status = "correct" if score == item["max_score_units"] else "partial" if score else "incorrect"
                    rows.append({"item_id": item["id"], "status": status,
                                 "awarded_score_units": score, "max_score_units": item["max_score_units"],
                                 "matched_token_count": matched})
                    continue
                if item["response_type"] == "multi_choice":
                    if answer is None:
                        answer = []
                    if not isinstance(answer, list) or any(not isinstance(a, str) for a in answer) or len(answer) != len(set(answer)):
                        raise InvalidExam(f"Expected unique string choices: {item['id']}")
                    correct = any(set(answer) == set(accepted) for accepted in item["grading"]["accepted_answers"])
                else:
                    if answer is None:
                        answer = ""
                    if not isinstance(answer, str):
                        raise InvalidExam(f"Expected text/choice string: {item['id']}")
                    ignore_case = item["grading"].get("ignore_case", False)
                    correct = any(normalized(answer, ignore_case) == normalized(accepted, ignore_case)
                                  for accepted in item["grading"]["accepted_answers"])
                allowed = item.get("option_ids", [])
                values = answer if isinstance(answer, list) else [answer]
                if allowed and any(v and v not in allowed for v in values):
                    raise InvalidExam(f"Unknown selected option: {item['id']}")
                rows.append({"item_id": item["id"], "status": "correct" if correct else "incorrect",
                             "awarded_score_units": item["max_score_units"] if correct else 0,
                             "max_score_units": item["max_score_units"]})
        pending = any(row["awarded_score_units"] is None for row in rows)
        awarded = sum(row["awarded_score_units"] or 0 for row in rows)
        result.append({"section_id": section["id"], "status": "pending" if pending else "graded",
                       "score_units": None if pending else awarded, "objective_score_units": awarded,
                       "max_score_units": section["max_score_units"], "items": rows})
    return {"exam_id": exam["id"], "revision": exam["revision"], "ai_integration": "stub_no_inference", "sections": result}


class PreviewHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self'; object-src 'self'; base-uri 'none'")
        super().end_headers()

    def do_POST(self):
        if urlsplit(self.path).path != "/api/grade":
            self.send_error(404)
            return
        expected = {f"http://127.0.0.1:{self.server.server_port}", f"http://localhost:{self.server.server_port}"}
        if self.headers.get("Origin") not in expected | {None}:
            self.send_error(403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 1_000_000 or self.headers.get_content_type() != "application/json":
                raise InvalidExam("Expected an application/json attempt up to 1 MB")
            request = json.loads(self.rfile.read(length))
            if not isinstance(request, dict):
                raise InvalidExam("Attempt must be an object")
            result = grade_attempt(self.server.exam, request)
            payload = (json.dumps(result, ensure_ascii=False) + "\n").encode()
        except (ValueError, KeyError, TypeError) as exc:
            self.send_error(400, str(exc))
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def translate_path(self, path):
        relative = unquote(urlsplit(path).path).lstrip("/")
        if not relative:
            relative = "index.html"
        if relative in {"index.html", "app.mjs", "logic.mjs", "styles.css"}:
            return str(self.server.bundle / "web" / relative)
        if relative in {"exam.json", "audio.json", "ai-assessment.json", "quality-report.json", "artifact-manifest.json", "exam.schema.json"} or relative.startswith(("sources/", "evidence/", "alignment/")):
            try:
                return str(inside(self.server.bundle, relative))
            except InvalidExam:
                pass
        return str(self.server.bundle / ".not-found")

    def send_head(self):
        """Single HTTP byte ranges are essential for seeking in the original MP3."""
        self._remaining = None
        path = Path(self.translate_path(self.path))
        if not path.is_file():
            self.send_error(404)
            return None
        size = path.stat().st_size
        start, end = 0, size - 1
        requested = self.headers.get("Range")
        if requested:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", requested)
            try:
                if not match or not any(match.groups()):
                    raise ValueError()
                left, right = match.groups()
                if left:
                    start = int(left)
                    end = min(int(right), size - 1) if right else size - 1
                else:
                    count = int(right)
                    if count <= 0:
                        raise ValueError()
                    start = max(0, size - count)
                if not 0 <= start <= end < size:
                    raise ValueError()
            except ValueError:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return None
        stream = path.open("rb")
        stream.seek(start)
        self._remaining = max(0, end - start + 1)
        self.send_response(206 if requested else 200)
        self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(self._remaining))
        if requested:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        return stream

    def copyfile(self, source, outputfile):
        remaining = self._remaining
        try:
            while remaining:
                block = source.read(min(64 * 1024, remaining))
                if not block:
                    break
                outputfile.write(block)
                remaining -= len(block)
        except (BrokenPipeError, ConnectionResetError):
            pass


def serve(bundle, port):
    bundle = Path(bundle).resolve()
    exam = read_json(bundle / "exam.json")
    validate_exam(exam, bundle)
    server = ThreadingHTTPServer(("127.0.0.1", port), PreviewHandler)
    server.bundle, server.exam = bundle, exam
    print(f"Local exam: http://127.0.0.1:{server.server_port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Local exam server stopped.", flush=True)
    finally:
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("extract", "build"):
        command = sub.add_parser(name)
        command.add_argument("--profile", type=Path, required=name == "build")
        if name == "extract":
            command.add_argument("--year", type=int)
            command.add_argument("--session")
            command.add_argument("--level")
        command.add_argument("--sources-root", type=Path, required=True)
        command.add_argument("--output", type=Path, required=True)
        command.add_argument("--no-render", action="store_true", help="Skip optional source-page PNG evidence")
        if name == "build":
            command.add_argument("--audio-alignment", type=Path)
    command = sub.add_parser("validate")
    command.add_argument("bundle", type=Path)
    command = sub.add_parser("serve")
    command.add_argument("bundle", type=Path)
    command.add_argument("--port", type=int, default=8773)
    args = parser.parse_args()
    try:
        if args.command == "extract":
            if args.output.exists():
                raise InvalidExam("Extraction output already exists")
            if args.profile:
                selection = read_json(args.profile)["source_selection"]
            elif all(value is not None for value in (args.year, args.session, args.level)):
                selection = {"year": args.year, "session": args.session, "level": args.level}
            else:
                raise InvalidExam("Provide --profile or all of --year, --session, --level")
            docs = extract_evidence(select_sources(args.sources_root, selection), args.output, not args.no_render)
            print(json.dumps({"documents": len(docs), "pages": sum(len(doc["pages"]) for doc in docs)}))
        elif args.command == "build":
            print(json.dumps(build(args.profile, args.sources_root, args.output, args.audio_alignment, not args.no_render), ensure_ascii=False, indent=2))
        elif args.command == "validate":
            exam = read_json(args.bundle / "exam.json")
            report = validate_exam(exam, args.bundle)
            if (args.bundle / "audio.json").exists():
                report["audio"] = validate_audio(read_json(args.bundle / "audio.json"), exam)
            for row in read_json(args.bundle / "artifact-manifest.json")["artifacts"]:
                path = inside(args.bundle, row["path"])
                if not path.is_file() or path.stat().st_size != row["bytes"] or digest(path) != row["sha256"]:
                    raise InvalidExam(f"Artifact changed: {row['path']}")
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            serve(args.bundle, args.port)
    except (ValueError, OSError, KeyError) as exc:
        parser.exit(1, f"Exam digitizer: {exc}\n")


if __name__ == "__main__":
    main()
