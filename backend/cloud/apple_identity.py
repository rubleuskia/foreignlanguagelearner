"""Fresh native Apple proof, verified account binding and consent revocation. No token storage."""
import hmac
import json
import time
import urllib.parse
import urllib.request
import urllib.error
import jwt
from backend.cloud.errors import CloudError


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, 'Redirect refused', headers, fp)


class AppleConsent:
    def __init__(self, client_id, team_id, key_id, private_key, opener=None, jwks=None):
        self.client_id, self.team_id, self.key_id, self.private_key = client_id, team_id, key_id, private_key
        self.opener = opener or urllib.request.build_opener(NoRedirect()).open
        self.jwks = jwks or jwt.PyJWKClient('https://appleid.apple.com/auth/keys', timeout=5)

    def _post(self, path, fields):
        request = urllib.request.Request('https://appleid.apple.com/auth/' + path,
            data=urllib.parse.urlencode(fields).encode(), headers={'Content-Type': 'application/x-www-form-urlencoded'}, method='POST')
        try:
            with self.opener(request, timeout=8) as response:
                raw = response.read(32769)
        except urllib.error.HTTPError as error:
            raise CloudError('APPLE_REAUTH_REQUIRED' if path == 'token' and error.code == 400 else 'APPLE_VERIFICATION_UNAVAILABLE',
                             400 if path == 'token' and error.code == 400 else 503) from None
        except (OSError, TimeoutError): raise CloudError('APPLE_VERIFICATION_UNAVAILABLE',503) from None
        if len(raw) > 32768: raise CloudError('APPLE_VERIFICATION_UNAVAILABLE', 503)
        return json.loads(raw) if raw else {}

    def prepare(self, authorization_code, apple_subject):
        if not apple_subject: raise CloudError('APPLE_ACCOUNT_NOT_LINKED', 409)
        now = int(time.time())
        secret = jwt.encode({'iss': self.team_id, 'iat': now, 'exp': now + 300,
            'aud': 'https://appleid.apple.com', 'sub': self.client_id}, self.private_key,
            algorithm='ES256', headers={'kid': self.key_id})
        tokens = self._post('token', {'client_id': self.client_id, 'client_secret': secret,
            'grant_type': 'authorization_code', 'code': authorization_code})
        try:
            signed = tokens['id_token']
            signing_key = self.jwks.get_signing_key_from_jwt(signed).key
            identity = jwt.decode(signed, signing_key, algorithms=['RS256'], audience=self.client_id,
                issuer='https://appleid.apple.com', options={'require': ['exp', 'iat', 'sub', 'aud', 'iss']}, leeway=5)
            if not hmac.compare_digest(identity['sub'], apple_subject): raise CloudError('APPLE_ACCOUNT_CONFLICT', 409)
            token = tokens.get('refresh_token') or tokens['access_token']
            if not isinstance(token, str) or not token or len(token) > 8192: raise ValueError()
            hint = 'refresh_token' if tokens.get('refresh_token') else 'access_token'
            return {'client_id': self.client_id, 'client_secret': secret, 'token': token, 'token_type_hint': hint}
        except CloudError: raise
        except jwt.PyJWKClientConnectionError: raise CloudError('APPLE_VERIFICATION_UNAVAILABLE',503) from None
        except Exception: raise CloudError('INVALID_APPLE_IDENTITY', 400) from None

    def revoke(self, prepared):
        self._post('revoke', prepared)
