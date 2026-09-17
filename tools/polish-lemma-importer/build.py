#!/usr/bin/env python3
"""Build the compact Polish form-to-Wiktionary-title database bundled by the app."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import sqlite3
import sys
import unicodedata
import zlib
from pathlib import Path


DEFAULT_SOURCE_URL = (
    "https://download.sgjp.pl/morfeusz/20260823/sgjp-20260823.tab.gz"
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert an official SGJP .tab.gz feed into an app lookup database."
    )
    parser.add_argument("--input", required=True, type=Path, help="SGJP .tab.gz file")
    parser.add_argument("--output", required=True, type=Path, help="Output SQLite file")
    parser.add_argument(
        "--compressed-output",
        type=Path,
        help="Optional zlib-compressed database to bundle with the app",
    )
    parser.add_argument("--source-url", default=DEFAULT_SOURCE_URL)
    return parser.parse_args()


def dictionary_title(raw_lemma: str) -> str:
    """Remove SGJP's lexeme disambiguator and decode spaces used by Morfeusz."""
    title = raw_lemma.split(":", 1)[0].replace("_", " ")
    return unicodedata.normalize("NFC", title).strip()


def normalized_form(raw_form: str) -> str:
    return unicodedata.normalize("NFC", raw_form).strip().lower()


def source_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def compress_database(source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".building")
    temporary.unlink(missing_ok=True)
    # Apple's Compression framework expects a raw DEFLATE stream for `.zlib`.
    compressor = zlib.compressobj(level=9, wbits=-zlib.MAX_WBITS)
    with source.open("rb") as input_stream, temporary.open("wb") as output_stream:
        while block := input_stream.read(1024 * 1024):
            output_stream.write(compressor.compress(block))
        output_stream.write(compressor.flush())
    os.replace(temporary, output)


def records(path: Path):
    copyright_finished = False
    with gzip.open(path, "rt", encoding="utf-8", newline="") as stream:
        for line_number, line in enumerate(stream, start=1):
            line = line.rstrip("\r\n")
            if not copyright_finished:
                copyright_finished = line == "#</COPYRIGHT>"
                continue
            if not line:
                continue
            columns = line.split("\t")
            if len(columns) < 3:
                raise ValueError(f"Malformed SGJP row at line {line_number}")
            form = normalized_form(columns[0])
            title = dictionary_title(columns[1])
            if form and title:
                yield form, title


def build(source: Path, output: Path, source_url: str) -> None:
    if not source.is_file():
        raise FileNotFoundError(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".building")
    temporary.unlink(missing_ok=True)

    connection = sqlite3.connect(temporary)
    try:
        connection.executescript(
            """
            PRAGMA page_size = 4096;
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            PRAGMA locking_mode = EXCLUSIVE;
            PRAGMA temp_store = MEMORY;
            CREATE TABLE lemma_lookup (
                form TEXT NOT NULL,
                title TEXT NOT NULL,
                PRIMARY KEY (form, title)
            ) WITHOUT ROWID;
            CREATE TABLE metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) WITHOUT ROWID;
            """
        )
        cursor = connection.cursor()
        batch: list[tuple[str, str]] = []
        source_rows = 0
        for record in records(source):
            batch.append(record)
            source_rows += 1
            if len(batch) == 25_000:
                cursor.executemany(
                    "INSERT OR IGNORE INTO lemma_lookup(form, title) VALUES (?, ?)", batch
                )
                batch.clear()
                if source_rows % 500_000 == 0:
                    print(f"Read {source_rows:,} SGJP rows", file=sys.stderr, flush=True)
        if batch:
            cursor.executemany(
                "INSERT OR IGNORE INTO lemma_lookup(form, title) VALUES (?, ?)", batch
            )

        unique_pairs = cursor.execute("SELECT count(*) FROM lemma_lookup").fetchone()[0]
        unique_forms = cursor.execute(
            "SELECT count(*) FROM (SELECT form FROM lemma_lookup GROUP BY form)"
        ).fetchone()[0]
        dictionary_id = cursor.execute(
            "SELECT title FROM lemma_lookup WHERE form = 'został' AND title = 'zostać'"
        ).fetchone()
        if dictionary_id is None:
            raise ValueError("Generated database failed the został → zostać validation")

        metadata = {
            "format_version": "1",
            "source": "SGJP / Morfeusz 2",
            "source_url": source_url,
            "source_sha256": source_sha256(source),
            "source_rows": str(source_rows),
            "unique_forms": str(unique_forms),
            "unique_pairs": str(unique_pairs),
            "license": "BSD-2-Clause",
        }
        cursor.executemany("INSERT INTO metadata(key, value) VALUES (?, ?)", metadata.items())
        connection.commit()
        connection.execute("PRAGMA optimize")
        connection.execute("VACUUM")
    finally:
        connection.close()

    os.replace(temporary, output)
    print(
        f"Created {output}: {unique_pairs:,} pairs for {unique_forms:,} forms "
        f"from {source_rows:,} SGJP rows",
        file=sys.stderr,
    )


if __name__ == "__main__":
    options = arguments()
    build(options.input, options.output, options.source_url)
    if options.compressed_output:
        compress_database(options.output, options.compressed_output)
        print(f"Compressed database to {options.compressed_output}", file=sys.stderr)
