"""API Gateway validates JWT signatures; Cognito checks the live session too."""
from dataclasses import dataclass
import json
from .errors import CloudError


@dataclass(frozen=True)
class Identity:
    user_id: str
    username: str
    apple_subject: str | None = None
    auth_time: int = 0


class IdentityService:
    def __init__(self, cognito, issuer, client_id, scope, *, pool_id=None, account_lookup=None):
        self.cognito, self.issuer, self.client_id, self.scope = cognito, issuer, client_id, scope
        self.pool_id, self.account_lookup = pool_id, account_lookup

    def authenticate(self, event):
        claims = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
        if (claims.get("iss") != self.issuer or claims.get("client_id") != self.client_id
                or claims.get("token_use") != "access" or not claims.get("sub")
                or self.scope not in claims.get("scope", "").split()):
            raise CloudError("UNAUTHORIZED", 401)
        headers = {k.lower(): v for k, v in event.get("headers", {}).items()}
        authorization = headers.get("authorization", "")
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not token:
            raise CloudError("UNAUTHORIZED", 401)
        try:
            user = self.cognito.get_user(AccessToken=token)
        except self.cognito.exceptions.NotAuthorizedException:
            raise CloudError("SESSION_REVOKED", 401) from None
        except self.cognito.exceptions.UserNotFoundException:
            raise CloudError("SESSION_REVOKED", 401) from None
        attributes = {a["Name"]: a["Value"] for a in user["UserAttributes"]}
        if attributes.get("sub") != claims["sub"]:
            raise CloudError("UNAUTHORIZED", 401)
        if self.pool_id and 'identities' not in attributes:
            attributes.update({a['Name']:a['Value'] for a in self.cognito.admin_get_user(
                UserPoolId=self.pool_id, Username=user['Username'])['UserAttributes']})
        try:
            providers = json.loads(attributes.get("identities", "[]"))
            apple_subject = next((p['userId'] for p in providers if p.get('providerName') == 'SignInWithApple'), None)
        except (ValueError, TypeError, KeyError): apple_subject = None
        try: auth_time = int(claims.get('auth_time', 0))
        except (ValueError,TypeError): raise CloudError('UNAUTHORIZED',401) from None
        if self.pool_id and (not apple_subject or auth_time <= 0): raise CloudError('APPLE_IDENTITY_UNAVAILABLE',403)
        account = self.account_lookup(claims['sub']) if self.account_lookup else None
        if account and auth_time <= account.get('valid_after', -1): raise CloudError('SESSION_REVOKED',401)
        return Identity(claims["sub"], user["Username"], apple_subject, auth_time)
