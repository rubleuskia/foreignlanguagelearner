"""Small authenticated API; processing can only be requested through the queue."""
import base64
import json
import os
import re
import time
from backend.cloud.errors import CloudError
from backend.private_cloud.api import runtime as auth_runtime, response, parse_body
from backend.private_cloud.auth import authenticate
from .contract import ARCHIVE_LIMIT, SYSTEM_OWNER, TERMINAL, validate_create
from .repository import Repository, public

_runtime = None


def runtime():
    global _runtime
    if _runtime is None:
        import boto3
        from botocore.config import Config
        config = Config(connect_timeout=3, read_timeout=5, retries={'total_max_attempts': 3, 'mode': 'standard'})
        table = boto3.resource('dynamodb', config=config).Table(os.environ['BOOK_ALIGNMENT_TABLE'])
        _runtime = Repository(table), boto3.client('s3', config=config)
    return _runtime


def input_key(row):
    return f"books/{row['owner']}/{row['job_id']}/input.zip"


def handle(event, repo, s3, bucket, owner=SYSTEM_OWNER):
    route = event.get('routeKey', '')
    params = event.get('pathParameters') or {}
    if route == 'GET /v1/book-alignments':
        cursor = (event.get('queryStringParameters') or {}).get('cursor')
        if cursor and not re.fullmatch('[0-9a-f]{64}', cursor):
            raise CloudError('INVALID_CURSOR')
        rows, next_cursor = repo.list(owner, cursor)
        return {'jobs': [public(row) for row in rows], 'cursor': next_cursor}
    if route == 'POST /v1/book-alignments':
        headers = {k.lower(): v for k, v in event.get('headers', {}).items()}
        body = validate_create(parse_body(event))
        return public(repo.create(owner, headers.get('idempotency-key', ''), body, int(time.time())))
    job_id = params.get('id', '')
    if not re.fullmatch('[0-9a-f]{64}', job_id):
        raise CloudError('NOT_FOUND', 404)
    row = repo.get(owner, job_id)
    if route == 'GET /v1/book-alignments/{id}':
        return public(row)
    if route == 'POST /v1/book-alignments/{id}/upload':
        if row['status'] != 'awaiting_upload':
            raise CloudError('INVALID_STATE', 409)
        checksum = base64.b64encode(bytes.fromhex(row['sha256'])).decode()
        headers = {'content-type': 'application/zip', 'x-amz-checksum-sha256': checksum,
                   'x-amz-sdk-checksum-algorithm': 'SHA256',
                   'x-amz-server-side-encryption': 'AES256'}
        url = s3.generate_presigned_url('put_object', Params={'Bucket': bucket, 'Key': input_key(row),
            'ContentLength': int(row['size_bytes']), 'ContentType': 'application/zip',
            'ChecksumSHA256': checksum, 'ChecksumAlgorithm': 'SHA256', 'ServerSideEncryption': 'AES256'}, ExpiresIn=900)
        return {'url': url, 'headers': headers}
    if route in {'POST /v1/book-alignments/{id}/complete', 'POST /v1/book-alignments/{id}/start'}:
        if row['status'] == 'awaiting_upload':
            try:
                head = s3.head_object(Bucket=bucket, Key=input_key(row), ChecksumMode='ENABLED')
            except s3.exceptions.ClientError as error:
                if error.response['ResponseMetadata']['HTTPStatusCode'] == 404:
                    raise CloudError('UPLOAD_NOT_FOUND', 409) from None
                raise
            if not 0 < head['ContentLength'] <= ARCHIVE_LIMIT:
                raise CloudError('INPUT_TOO_LARGE', 413)
            checksum = base64.b64encode(bytes.fromhex(row['sha256'])).decode()
            if head['ContentLength'] != row['size_bytes'] or head.get('ChecksumSHA256') != checksum:
                raise CloudError('CHECKSUM_MISMATCH', 409)
            if not head.get('VersionId'):
                raise CloudError('INFRASTRUCTURE_FAILURE', 503)
            row = repo.change(row, 'uploaded', 0, input_version=head['VersionId'])
        if route.endswith('/start') and row['status'] == 'uploaded':
            # DynamoDB Stream is the durable outbox. No direct inference or RunTask call.
            row = repo.change(row, 'queued', 5)
        return public(row)
    if route == 'GET /v1/book-alignments/{id}/result':
        if row['status'] not in TERMINAL - {'failed'}:
            raise CloudError('RESULT_NOT_READY', 409)
        artifact = row['result']
        remaining = int(row['updated_at']) + 30 * 86400 - int(time.time())
        if remaining <= 0:
            raise CloudError('RESULT_EXPIRED', 410)
        try:
            s3.head_object(Bucket=bucket, Key=artifact['key'], VersionId=artifact['version_id'])
        except s3.exceptions.ClientError as error:
            if error.response['ResponseMetadata']['HTTPStatusCode'] == 404:
                raise CloudError('RESULT_EXPIRED', 410) from None
            raise
        return {**artifact, 'bytes': int(artifact['bytes']), 'url': s3.generate_presigned_url('get_object', Params={
            'Bucket': bucket, 'Key': artifact['key'], 'VersionId': artifact['version_id']}, ExpiresIn=min(900, remaining))}
    raise CloudError('NOT_FOUND', 404)


def handler(event, context):
    try:
        cognito, auth_repo, _ = auth_runtime()
        authenticate(event, cognito, auth_repo)
        if os.environ.get('OPERATOR_ALIGNMENT', 'true') != 'true':
            raise CloudError('ALIGNMENT_DISABLED', 503)
        repo, s3 = runtime()
        return response(200, handle(event, repo, s3, os.environ['BOOK_ALIGNMENT_BUCKET']))
    except CloudError as error:
        return response(error.status, {'error': {'code': error.code}})
    except Exception:
        print(json.dumps({'event': 'book_alignment_api_error'}))
        return response(500, {'error': {'code': 'INFRASTRUCTURE_FAILURE'}})
