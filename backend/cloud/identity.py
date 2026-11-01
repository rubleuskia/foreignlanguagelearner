"""API Gateway validates JWT signatures; Cognito checks the live session too."""
from dataclasses import dataclass
from .errors import CloudError


@dataclass(frozen=True)
class Identity:
    user_id: str
    username: str


class IdentityService:
    def __init__(self, cognito, issuer, client_id, scope):
        self.cognito, self.issuer, self.client_id, self.scope = cognito, issuer, client_id, scope

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
        return Identity(claims["sub"], user["Username"])
