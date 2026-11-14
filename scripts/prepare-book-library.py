#!/usr/bin/env python3
"""Validate complete book archives and prepare an atomic S3 catalog publication.

Upload each file in uploads.json to its key first, then upload catalog.json last.
Archives are content-addressed so a failed publication cannot break the old catalog.
"""
import argparse
import hashlib
import json
import re
import unicodedata
from pathlib import Path
import zipfile


METADATA = Path(__file__).resolve().parents[1] / 'App/Resources/BookLibraryMetadata.json'


def prepare(source, output, metadata_path=METADATA):
    metadata = json.loads(metadata_path.read_text())
    books, uploads = [], []
    for path in sorted(source.glob('*/*.book.zip')):
        with zipfile.ZipFile(path) as archive:
            bad = archive.testzip()
            if bad:
                raise ValueError(f'Corrupt archive: {path.name}: {bad}')
            manifest = json.loads(archive.read('manifest.json'))
            if not manifest.get('tracks') or not manifest.get('transcript'):
                raise ValueError(f'Incomplete book: {path}')
            text = archive.read(manifest['transcript']).decode('utf-8')
            normalized = ' '.join(unicodedata.normalize('NFC', text.replace('\ufeff', '')).split())
            identity = normalized + '\0' + '\0'.join(track['id'] for track in manifest['tracks'])
        with path.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        book_id = path.parent.name
        if not re.fullmatch(r'[a-z0-9-]{1,120}', book_id):
            raise ValueError(f'Invalid stable catalog ID: {book_id}')
        if any(book['id'] == book_id for book in books):
            raise ValueError(f'Duplicate catalog ID: {book_id}')
        key = f'library/books/{book_id}/{digest}.zip'
        details = {k: v for k, v in metadata.get(book_id, {}).items()
                   if k in {'author', 'authorInfo', 'authorURL', 'coverName'}}
        books.append({'id': book_id, 'title': manifest['title'], 'language': manifest['sourceLanguage'],
                      'bytes': path.stat().st_size, 'sha256': digest, 'key': key,
                      'chapterCount': len(manifest['tracks']),
                      'contentFingerprint': hashlib.sha256(identity.encode('utf-8')).hexdigest(), **details})
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
