"""Synchronous operator API. No Apple, subscription or inference queue dependency."""
import base64
import hashlib
import json
import os
import time
import uuid
from backend.cloud.errors import CloudError
from backend.translation.contract import canonical, validate_input
from backend.translation.provider import ProviderFailure
from .auth import authenticate
from .repository import Repository
from .provider import BedrockProvider

_runtime = None


def runtime():
    global _runtime
    if _runtime is None:
        import boto3
        from botocore.config import Config
        options = Config(connect_timeout=2, read_timeout=3, retries={'total_max_attempts': 1})
        _runtime = (boto3.client('cognito-idp', config=options),
                    Repository(boto3.client('dynamodb', config=options), os.environ['OPERATOR_TABLE']),
                    BedrockProvider(boto3.client('bedrock-runtime', config=Config(
                        connect_timeout=2, read_timeout=18, retries={'total_max_attempts': 1}))))
    return _runtime


def response(status, value):
    return {'statusCode': status, 'headers': {'content-type': 'application/json', 'cache-control': 'no-store'},
            'body': json.dumps(value, ensure_ascii=False)}


def parse_body(event):
    raw = event.get('body') or ''
    try:
        if event.get('isBase64Encoded'):
            raw = base64.b64decode(raw, validate=True).decode()
        if len(raw.encode()) > 16384:
            raise CloudError('BODY_TOO_LARGE', 413)
        return json.loads(raw)
    except (ValueError, TypeError, UnicodeError):
        raise CloudError('INVALID_JSON') from None


def handler(event, context):
    try:
        cognito, repo, provider = runtime()
        owner = authenticate(event, cognito, repo)
        route = event.get('routeKey')
        if route == 'GET /v1/me':
            return response(200, {'schema_version': 1, 'user_id': owner, 'role': 'operator',
                'features': {'translations': True, 'alignment': os.environ.get('OPERATOR_ALIGNMENT', 'true') == 'true'}})
        if route == 'GET /v1/health':
            return response(200, {'schema_version': 1, 'status': 'ok', 'mode': 'operator'})
        now = int(time.time())
        params = event.get('pathParameters') or {}
        if route in {'GET /v1/requests/{id}', 'GET /v1/requests/by-key/{key}'}:
            request_id = params.get('id') if 'id' in params else repo.request_id(owner, params.get('key', ''))
            row = repo.get(request_id)
            if not row or row.get('owner') != owner:
                raise CloudError('NOT_FOUND', 404)
            return response(200, repo.public(row, now))
        kind = {'POST /v1/context-analyses': 'context', 'POST /v1/word-explanations': 'word'}.get(route)
        if not kind:
            raise CloudError('NOT_FOUND', 404)
        payload = validate_input(kind, parse_body(event))
        headers = {k.lower(): v for k, v in event.get('headers', {}).items()}
        key = headers.get('idempotency-key', '')
        try:
            if str(uuid.UUID(key)) != key:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise CloudError('INVALID_IDEMPOTENCY_KEY') from None
        if context and context.get_remaining_time_in_millis() < 22000:
            raise CloudError('DEADLINE_TOO_CLOSE', 503)
        fingerprint = hashlib.sha256(canonical({'kind': kind, 'payload': payload}).encode()).hexdigest()
        row, fresh = repo.admit(owner, key, fingerprint, now, int(os.environ['DAILY_MODEL_LIMIT']))
        if fresh:
            started = time.monotonic()
            try:
                result, tokens = provider.run(kind, payload)
                row = repo.finish(row, 'succeeded', result, tokens)
                print(json.dumps({'event': 'model_completed', 'request_id': row['request_id'],
                                  'duration_ms': round((time.monotonic() - started) * 1000), **tokens}))
            except ProviderFailure as error:
                state = 'outcome_unknown' if error.unknown else 'failed'
                row = repo.finish(row, state, tokens=error.tokens)
                print(json.dumps({'event': 'model_failed', 'state': state, 'request_id': row['request_id']}))
        value = repo.public(row, int(time.time()))
        return response(200 if value['state'] == 'succeeded' else 202, value)
    except CloudError as error:
        return response(error.status, {'error': {'code': error.code}})
    except Exception:
        print(json.dumps({'event': 'operator_api_error'}))
        return response(500, {'error': {'code': 'INFRASTRUCTURE_FAILURE'}})
