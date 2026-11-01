"""Lazy AWS composition; public certificates are packaged, credentials stay in Secrets Manager."""
import json
from functools import lru_cache
import os
from pathlib import Path
from backend.cloud.identity import IdentityService
from .repository import DynamoRepository
from .service import BillingService


def repository():
    import boto3
    return DynamoRepository(boto3.client("dynamodb"), os.environ["ACCOUNTS_TABLE"],
        os.environ["SUBSCRIPTIONS_TABLE"], os.environ.get("BILLING_EVENTS_TABLE", ""), os.environ["APPLE_ENVIRONMENT"])


def identity():
    import boto3
    return IdentityService(boto3.client("cognito-idp"), os.environ["JWT_ISSUER"],
                           os.environ["JWT_CLIENT_ID"], os.environ["JWT_SCOPE"])


@lru_cache(maxsize=1)
def apple_verifier():
    from appstoreserverlibrary.models.Environment import Environment
    from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier
    environment = Environment(os.environ["APPLE_ENVIRONMENT"])
    roots = [p.read_bytes() for p in sorted(Path(os.environ["APPLE_ROOTS_PATH"]).glob("*.cer"))]
    if not roots:
        raise RuntimeError("No reviewed Apple trust anchors packaged")
    # The SDK caches successfully checked certificate chains for its bounded 15-minute window.
    return SignedDataVerifier(roots, True, environment, os.environ["APPLE_BUNDLE_ID"],
        int(os.environ["APPLE_APP_ID"]) if os.environ.get("APPLE_APP_ID") else None)


def service(with_apple=False, verifier_only=False):
    gateway = None
    if with_apple:
        import boto3
        from appstoreserverlibrary.api_client import AppStoreServerAPIClient
        from appstoreserverlibrary.models.Environment import Environment
        from .apple import AppleGateway
        environment = Environment(os.environ["APPLE_ENVIRONMENT"])
        verifier = apple_verifier()
        client = None
        if not verifier_only:
            secret = json.loads(boto3.client("secretsmanager").get_secret_value(
                SecretId=os.environ["APPLE_API_SECRET_ARN"])["SecretString"])
            client = AppStoreServerAPIClient(secret["private_key"].encode(), secret["key_id"],
                secret["issuer_id"], os.environ["APPLE_BUNDLE_ID"], environment)
        gateway = AppleGateway(verifier, client, environment=environment.value,
            bundle_id=os.environ["APPLE_BUNDLE_ID"], products=json.loads(os.environ["APPLE_PRODUCTS"]))
    return BillingService(repository(), gateway)
