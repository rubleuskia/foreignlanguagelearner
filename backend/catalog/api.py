"""Small authenticated catalog routes, served by the existing book-alignment API."""
import hashlib
import os
import re
import time
from backend.cloud.errors import CloudError
from backend.book_alignment.contract import SYSTEM_OWNER, TERMINAL
from backend.book_alignment.repository import public as job_public
from .repository import Catalog
from .source import PIPELINE


def runtime():
    import boto3
    return Catalog(boto3.resource('dynamodb').Table(os.environ['BOOK_CATALOG_TABLE']))


def job_id(book):
    return hashlib.sha256((book['id'] + ':' + book['sourceVersion'] + ':' + PIPELINE).encode()).hexdigest()


def admit(repo, identity, fields, *, restart=False):
    now = int(time.time())
    row = {'owner': SYSTEM_OWNER, 'job_id': identity, 'status': 'queued', 'progress': 5,
           'revision': 0, 'created_at': now, 'updated_at': now, 'attempts': 0,
           'history': [{'status': 'queued', 'at': now}], 'dispatch_state': 'active', 'ready_at': 0, **fields}
    try:
        repo.table.put_item(Item=row, ConditionExpression='attribute_not_exists(job_id)')
        return row
    except repo.table.meta.client.exceptions.ConditionalCheckFailedException:
        previous = repo.get(SYSTEM_OWNER, identity)
        if restart and previous['status'] in TERMINAL:
            try:
                return repo.change(previous, 'queued', 5, attempts=0, error_code='', result={}, lease_until=0)
            except CloudError as error:
                if error.code != 'STATE_CHANGED': raise
                return repo.get(SYSTEM_OWNER, identity)
        return previous


def valid_result(row, s3, bucket):
    if row['status'] not in {'succeeded', 'succeeded_with_review'}: return False
    result = row.get('result') or {}
    try:
        s3.head_object(Bucket=bucket, Key=result['key'], VersionId=result['version_id'])
        return True
    except s3.exceptions.ClientError as error:
        if error.response['ResponseMetadata']['HTTPStatusCode'] in {404, 405}: return False
        raise
    except KeyError: return False


def handle(event, repo, s3, catalog=None):
    catalog = catalog or runtime()
    route = event['routeKey']
    if route == 'POST /v1/catalog/refresh':
        return job_public(admit(repo, hashlib.sha256(b'catalog-refresh').hexdigest(),
            {'kind': 'catalog_refresh', 'title': 'Wolne Lektury catalog', 'language': 'pl'}, restart=True))
    if route == 'GET /v1/catalog/books':
        cursor = (event.get('queryStringParameters') or {}).get('cursor')
        generation = after = None
        if cursor:
            match = re.fullmatch(r'([a-f0-9]{32}):([a-z0-9-]{1,120})', cursor)
            if not match: raise CloudError('INVALID_CURSOR')
            generation, after = match.groups()
        books, after, generation = catalog.page(generation, after)
        return {'books': books, 'cursor': f'{generation}:{after}' if after else None}
    book_id = (event.get('pathParameters') or {}).get('id', '')
    if not re.fullmatch('[a-z0-9-]{1,120}', book_id): raise CloudError('NOT_FOUND', 404)
    book = catalog.get(book_id)
    if route == 'GET /v1/catalog/books/{id}':
        from .repository import public
        return {**public(book), 'chapters': [t['title'] for t in book['source']['tracks']]}
    if route == 'POST /v1/catalog/books/{id}/import':
        identity = job_id(book)
        previous = None
        try: previous = repo.get(SYSTEM_OWNER, identity)
        except CloudError as error:
            if error.code != 'NOT_FOUND': raise
        restart = previous is not None and previous['status'] in TERMINAL and not valid_result(previous, s3, os.environ['BOOK_LIBRARY_BUCKET'])
        return job_public(admit(repo, identity, {'kind': 'catalog_import', 'title': book['title'][:200],
            'language': 'pl', 'catalog_id': book['id'], 'source_version': book['sourceVersion'],
            'source_book': book, 'pipeline': PIPELINE}, restart=restart))
    if route == 'GET /v1/catalog/books/{id}/import':
        try: return job_public(repo.get(SYSTEM_OWNER, job_id(book)))
        except CloudError as error:
            if error.code == 'NOT_FOUND': return {'job': None}
            raise
    raise CloudError('NOT_FOUND', 404)
