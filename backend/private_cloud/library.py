"""Private curated catalog. All calls are authenticated by the operator API first."""
import json
import os
import re
from backend.cloud.errors import CloudError


def client():
    import boto3
    from botocore.config import Config
    return boto3.client('s3', config=Config(signature_version='s3v4', connect_timeout=3,
        read_timeout=10, retries={'max_attempts': 2}))


def handle(route, params, s3=None):
    s3 = s3 or client()
    bucket = os.environ['BOOK_LIBRARY_BUCKET']
    with s3.get_object(Bucket=bucket, Key='library/catalog.json')['Body'] as body:
        catalog = json.loads(body.read())
    books = catalog['books']
    if route == 'GET /v1/library/books':
        return {'schema_version': 1, 'books': [{k: v for k, v in book.items() if k != 'key'} for book in books]}
    book_id = params.get('id', '')
    if not re.fullmatch(r'[a-z0-9-]{1,120}', book_id):
        raise CloudError('NOT_FOUND', 404)
    book = next((b for b in books if b['id'] == book_id), None)
    if book is None:
        raise CloudError('NOT_FOUND', 404)
    key = book['key']
    if not key.startswith('library/books/') or not key.endswith('.zip') or '..' in key:
        raise ValueError('Invalid catalog object key')
    # Do not issue a successful download response for a missing object.
    s3.head_object(Bucket=bucket, Key=key)
    return {'schema_version': 1, 'url': s3.generate_presigned_url('get_object',
        Params={'Bucket': bucket, 'Key': key}, ExpiresIn=900), 'expires_in': 900,
        'bytes': book['bytes'], 'sha256': book['sha256']}
