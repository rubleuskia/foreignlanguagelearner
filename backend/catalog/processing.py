"""Worker-side refresh and on-demand source staging; no media is bulk downloaded."""
import hashlib
import json
import time
import zipfile
from pathlib import Path

from backend.book_alignment.contract import ARCHIVE_LIMIT, TEXT_LIMIT
from backend.cloud.errors import CloudError
from . import source
from .repository import Catalog


def refresh(catalog, check, stage, guard=None):
    listing = source.get_json(source.API + 'audiobooks/?format=json')
    if not isinstance(listing, list) or not listing: raise CloudError('INVALID_SOURCE')
    books = []
    for index, item in enumerate(listing):
        check()
        detail = source.get_json(source.API + 'books/' + item['slug'] + '/?format=json')
        book = source.normalize(item['slug'], detail)
        if book:
            # Bound each remote operation; refresh the lease even during very large books.
            validators = []
            for url in [book['source']['text']] + [t['url'] for t in book['source']['tracks']]:
                check()
                with source.open_url(url, media=True, method='HEAD') as response:
                    validators.append({'url': url, 'etag': response.headers.get('ETag', ''),
                        'modified': response.headers.get('Last-Modified', ''),
                        'bytes': int(response.headers.get('Content-Length', 0))})
            books.append(source.normalize(item['slug'], detail, validators=validators))
        stage('preparing', 10 + int(80 * (index + 1) / len(listing)))
    catalog.publish(books, check, guard)
    return len(books)


def stage_book(book, root, s3, bucket, stage):
    spec = book['source']
    if len(spec['tracks']) > source.MAX_TRACKS:
        raise ValueError('TRACK_LIMIT_EXCEEDED')
    validators = spec.get('validators', [])
    declared = sum(int(v.get('bytes', 0)) for v in validators)
    if declared > ARCHIVE_LIMIT: raise ValueError('INPUT_TOO_LARGE')
    inputs = root / 'source'; inputs.mkdir()
    definitions = [(spec['text'], 'text.' + spec['textFormat'])] + [
        (t['url'], f'audio/{i:03d}.mp3') for i, t in enumerate(spec['tracks'], 1)]
    used = 0
    hashes = []
    for index, (url, name) in enumerate(definitions):
        path = inputs / name; path.parent.mkdir(exist_ok=True)
        key = f"sources/{book['id']}/{book['sourceVersion']}/{name}"
        try:
            cached = s3.get_object(Bucket=bucket, Key=key)
        except s3.exceptions.ClientError as error:
            if error.response['ResponseMetadata']['HTTPStatusCode'] != 404: raise
            cached = None
        if cached:
            count = 0; digest = hashlib.sha256()
            with cached['Body'] as incoming, path.open('xb') as output:
                for block in iter(lambda: incoming.read(1024 * 1024), b''):
                    count += len(block)
                    if used + count > ARCHIVE_LIMIT: raise ValueError('INPUT_TOO_LARGE')
                    digest.update(block); output.write(block)
            sha = digest.hexdigest()
            if not count or count != cached['ContentLength'] or sha != cached.get('Metadata', {}).get('sha256'):
                raise ValueError('CHECKSUM_MISMATCH')
        else:
            expected = next((v for v in validators if v['url'] == url), None)
            try: count, sha = source.download(url, path, min(ARCHIVE_LIMIT - used, TEXT_LIMIT if index == 0 else ARCHIVE_LIMIT), expected)
            except CloudError as error: raise ValueError(error.code) from None
            with path.open('rb') as stream:
                s3.put_object(Bucket=bucket, Key=key, Body=stream, Metadata={'sha256': sha}, ServerSideEncryption='AES256')
        used += count; hashes.append({'path': name, 'sha256': sha})
        stage('downloading', 10 + int(4 * (index + 1) / len(definitions)))
    provenance = {'provider': 'Wolne Lektury', 'url': book['sourceURL'], 'title': book['title'],
        'author': book['author'], 'sourceVersion': book['sourceVersion'], 'files': hashes,
        'narration': spec['tracks'], 'licenseInfoURL': 'https://wolnelektury.pl/info/zasady-wykorzystania/'}
    if spec['textFormat'] == 'txt':
        text = (inputs / 'text.txt').read_text(encoding='utf-8-sig').replace('\r\n', '\n')
        # Only remove the known provider footer. Preserve it verbatim in the package.
        marker = '\n-----\nTa lektura, podobnie jak'
        offset = text.rfind(marker)
        if offset >= 0:
            provenance['originalNotices'] = text[offset:]
            text = text[:offset]
        (inputs / 'text.txt').write_text(text, encoding='utf-8')
    else:
        # The original EPUB is retained in the source cache with its notices intact.
        provenance['originalTextURL'] = spec['text']
    cover = book.get('coverURL')
    if cover and cover.endswith(('.jpg', '.jpeg', '.png')):
        try:
            source.download(cover, inputs / 'cover.jpg', min(2_000_000, ARCHIVE_LIMIT - used))
        except (CloudError, OSError):
            (inputs / 'cover.jpg').unlink(missing_ok=True)
    (inputs / 'provenance.json').write_text(json.dumps(provenance, ensure_ascii=False), encoding='utf-8')
    manifest = {'schemaVersion': 1, 'audio': [name for _, name in definitions[1:]], 'text': definitions[0][1]}
    (inputs / 'input.json').write_text(json.dumps(manifest), encoding='utf-8')
    archive = root / 'input.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as out:
        for path in sorted(inputs.rglob('*')):
            if path.is_file(): out.write(path, path.relative_to(inputs).as_posix())
    if archive.stat().st_size > ARCHIVE_LIMIT: raise ValueError('INPUT_TOO_LARGE')
    return archive
