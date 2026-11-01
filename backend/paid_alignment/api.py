import json
import base64
from backend.billing.api import response, safe
from backend.billing.runtime import identity
from backend.alignment.errors import AlignmentError
from backend.cloud.errors import CloudError
from . import runtime


def handler(event, _context):
    def run():
        owner = identity().authenticate(event).user_id
        service = runtime.service(owner)
        raw = event.get('body') or ''
        try:
            if event.get('isBase64Encoded'): raw = base64.b64decode(raw, validate=True).decode()
            if len(raw.encode()) > 16384: raise CloudError('BODY_TOO_LARGE', 413)
            body = json.loads(raw) if raw else None
        except (ValueError, TypeError, UnicodeError): raise CloudError('INVALID_JSON') from None
        route = event.get('routeKey', '')
        headers = {k.lower():v for k,v in event.get('headers',{}).items()}
        try:
            if route == 'POST /v2/alignments':
                status, value = service.create(body, None, headers.get('idempotency-key'))
                return response(status, value)
            job_id = (event.get('pathParameters') or {}).get('id')
            suffix = route.split('{id}')[-1]
            if not job_id: raise CloudError('NOT_FOUND', 404)
            if route.startswith('GET '):
                methods = {'':service.status, '/upload':service.upload_status, '/result':service.result, '/diagnostics':service.diagnostics}
                if suffix not in methods: raise CloudError('NOT_FOUND',404)
                return response(200, methods[suffix](job_id, None))
            methods = {'/upload-urls':service.upload_urls, '/complete-upload':service.complete_upload, '/start':service.start, '/cancel':service.cancel}
            if suffix not in methods: raise CloudError('NOT_FOUND',404)
            return response(202 if suffix in {'/start','/cancel'} else 200, methods[suffix](job_id, body, None))
        except AlignmentError as error: raise CloudError(error.code,error.status) from None
    return safe(run, event.get('requestContext',{}).get('requestId'))
