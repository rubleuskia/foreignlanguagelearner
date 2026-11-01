import base64
import json
from backend.billing.api import response, safe
from backend.billing.runtime import identity
from backend.cloud.errors import CloudError
from . import runtime


def handler(event, _context):
    def run():
        owner = identity().authenticate(event).user_id
        service = runtime.service()
        route = event.get('routeKey', '')
        request_id = (event.get('pathParameters') or {}).get('id')
        if route == 'GET /v1/requests/by-key/{key}': return response(200, service.status_by_key(owner, (event.get('pathParameters') or {}).get('key')))
        if route == 'GET /v1/requests/{id}': return response(200, service.status(owner, request_id))
        if route == 'POST /v1/requests/{id}/cancel': return response(200, service.cancel(owner, request_id))
        kind = {'POST /v1/context-analyses': 'context', 'POST /v1/word-explanations': 'word'}.get(route)
        if not kind: raise CloudError('NOT_FOUND', 404)
        raw = event.get('body') or ''
        try:
            if event.get('isBase64Encoded'): raw = base64.b64decode(raw, validate=True).decode()
            if len(raw.encode()) > 16384: raise CloudError('BODY_TOO_LARGE', 413)
            payload = json.loads(raw)
        except (ValueError, TypeError, UnicodeError): raise CloudError('INVALID_JSON') from None
        headers = {k.lower(): v for k, v in event.get('headers', {}).items()}
        return response(202, service.submit(owner, kind, payload, headers.get('idempotency-key')))
    return safe(run, event.get('requestContext', {}).get('requestId'))
