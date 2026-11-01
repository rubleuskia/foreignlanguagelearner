"""Separate entry points permit IAM separation for account, purchase and public webhook."""
import base64
import json
import os
from backend.cloud.errors import CloudError
from . import runtime


MAX_BODY_BYTES = 65536


def body(event, field):
    raw = event.get("body") or ""
    try:
        if event.get("isBase64Encoded"):
            raw = base64.b64decode(raw, validate=True).decode("utf-8")
        if len(raw.encode("utf-8")) > MAX_BODY_BYTES:
            raise CloudError("BODY_TOO_LARGE", 413)
        value = json.loads(raw)
    except (ValueError, TypeError, UnicodeError):
        raise CloudError("INVALID_JSON", 400) from None
    if (not isinstance(value, dict) or set(value) != {field} or not isinstance(value[field], str)
            or not value[field] or len(value[field]) > 60000):
        raise CloudError("INVALID_REQUEST", 400)
    return value[field]


def response(status, value):
    return {"statusCode": status, "headers": {"content-type": "application/json", "cache-control": "no-store"},
            "body": json.dumps(value, separators=(",", ":"))}


def safe(action, request_id=None):
    try:
        return action()
    except CloudError as error:
        if error.status >= 500:
            print(json.dumps({"operation": "billing_api", "request_id": request_id, "error": error.code}))
        return response(error.status, {"error": {"code": error.code}})
    except Exception:
        # SDK exceptions can contain raw JWS, tokens or credentials. Never log them.
        print(json.dumps({"operation": "billing_api", "request_id": request_id, "error": "infrastructure_failure"}))
        return response(503, {"error": {"code": "BILLING_TEMPORARILY_UNAVAILABLE"}})


def account_handler(event, _context):
    def run():
        identity = runtime.identity()
        user = identity.authenticate(event)
        service = runtime.service()
        route = event.get("routeKey")
        if route == "GET /v1/me":
            account = service.account(user.user_id)
            return response(200, {"schema_version": 1, "app_account_token": account["app_account_token"]})
        if route == "GET /v1/me/entitlements":
            return response(200, service.status(user.user_id))
        if route == "DELETE /v1/me":
            service.repository.account(user.user_id)
            service.repository.disable_account(user.user_id)
            try:
                identity.cognito.admin_delete_user(UserPoolId=os.environ["USER_POOL_ID"], Username=user.username)
            except identity.cognito.exceptions.UserNotFoundException:
                pass
            return response(200, {"deleted": True, "subscription_cancelled": False,
                "manage_subscription_url": "https://apps.apple.com/account/subscriptions"})
        raise CloudError("NOT_FOUND", 404)
    return safe(run, event.get("requestContext", {}).get("requestId"))


def sync_handler(event, _context):
    def run():
        user = runtime.identity().authenticate(event)
        signed = body(event, "signed_transaction")
        return response(200, runtime.service(with_apple=True).sync(user.user_id, signed))
    return safe(run, event.get("requestContext", {}).get("requestId"))


def webhook_handler(event, _context):
    def run():
        signed = body(event, "signedPayload")
        result = runtime.service(with_apple=True, verifier_only=True).webhook(signed)
        return response(200, result)
    return safe(run, event.get("requestContext", {}).get("requestId"))
