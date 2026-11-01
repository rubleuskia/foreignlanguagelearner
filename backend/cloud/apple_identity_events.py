"""Apple identity notifications are distinct from App Store subscription notifications."""
import hashlib
import json
import os
import time
import uuid
import jwt
from backend.billing.api import body, response, safe
from backend.billing import runtime
from backend.cloud.errors import CloudError


def verified_event(signed, audiences, jwks=None):
    jwks = jwks or jwt.PyJWKClient('https://appleid.apple.com/auth/keys', timeout=5)
    try:
        key = jwks.get_signing_key_from_jwt(signed).key
        value = jwt.decode(signed, key, algorithms=['RS256'], audience=audiences,
            issuer='https://appleid.apple.com', options={'require':['iss','aud','iat','jti','events']}, leeway=5)
        event = value['events']
        if isinstance(event, str): event = json.loads(event)
        if not isinstance(event, dict) or event.get('type') not in {'consent-revoked','account-deleted','email-enabled','email-disabled'}:
            raise CloudError('UNSUPPORTED_IDENTITY_EVENT')
        subject, occurred = event.get('sub'), event.get('event_time')
        if not isinstance(subject,str) or not subject or len(subject)>256 or type(occurred) is not int or occurred <= 0 or occurred > int(time.time())+60:
            raise CloudError('INVALID_IDENTITY_EVENT')
        if not isinstance(value['jti'],str) or not value['jti'] or len(value['jti'])>512: raise CloudError('INVALID_IDENTITY_EVENT')
        event_id = str(uuid.uuid5(uuid.NAMESPACE_URL, 'apple-identity:' + value['jti']))
        return event_id, {'identity_subject':subject,'identity_type':event['type'],'occurred_at':occurred}
    except CloudError: raise
    except jwt.PyJWKClientConnectionError: raise CloudError('APPLE_VERIFICATION_UNAVAILABLE',503) from None
    except Exception: raise CloudError('INVALID_APPLE_IDENTITY',400) from None


def handler(event, _context):
    def run():
        signed = body(event, 'payload')
        event_id, fields = verified_event(signed, json.loads(os.environ['APPLE_IDENTITY_AUDIENCES']))
        runtime.repository().record_identity_event(event_id, fields, int(time.time()))
        return response(200, {'accepted':True})
    return safe(run, event.get('requestContext',{}).get('requestId'))
