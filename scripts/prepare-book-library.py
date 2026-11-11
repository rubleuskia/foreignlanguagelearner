#!/usr/bin/env python3
"""Validate complete book archives and prepare an atomic S3 catalog publication.

Upload each file in uploads.json to its key first, then upload catalog.json last.
Archives are content-addressed so a failed publication cannot break the old catalog.
"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def prepare(source, output):
    books, uploads = [], []
    for path in sorted(source.glob('*/*.book.zip')):
        with zipfile.ZipFile(path) as archive:
            bad = archive.testzip()
            if bad:
                raise ValueError(f'Corrupt archive: {path.name}: {bad}')
            manifest = json.loads(archive.read('manifest.json'))
            if not manifest.get('tracks') or not manifest.get('transcript'):
                raise ValueError(f'Incomplete book: {path}')
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        book_id = path.parent.name
        key = f'library/books/{book_id}/{digest}.zip'
        books.append({'id': book_id, 'title': manifest['title'], 'language': manifest['sourceLanguage'],
                      'bytes': path.stat().st_size, 'sha256': digest, 'key': key})
        uploads.append({'path': str(path.resolve()), 'key': key})
    if not books:
        raise ValueError('No complete book archives found')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'catalog.json').write_text(json.dumps({'schema_version': 1, 'books': books}, ensure_ascii=False, indent=2))
    (output / 'uploads.json').write_text(json.dumps(uploads, indent=2))
    print(f'Validated {len(books)} books, {sum(b["bytes"] for b in books):,} bytes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    prepare(args.source, args.output)


if __name__ == '__main__':
    main()
