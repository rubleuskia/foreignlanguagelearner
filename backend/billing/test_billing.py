"""Billing invariants against a DynamoDB emulator and the real SDK model types."""
import copy
import json
import unittest
from dataclasses import replace
from types import SimpleNamespace as NS
from unittest.mock import Mock, patch
from uuid import uuid4

from backend.cloud.errors import CloudError
from backend.cloud.identity import IdentityService
from backend.billing.domain import Subscription, entitlement
from backend.billing.service import BillingService
from backend.billing import api, worker

try:
    import boto3
    from moto import mock_aws
    from appstoreserverlibrary.signed_data_verifier import VerificationException, VerificationStatus, SignedDataVerifier
    from appstoreserverlibrary.models.Environment import Environment
    from appstoreserverlibrary.api_client import AppStoreServerAPIClient
except ImportError:
    boto3 = None


@unittest.skipUnless(boto3, "Install backend/billing/requirements-dev.txt")
class BillingTests(unittest.TestCase):
    def setUp(self):
        self.aws = mock_aws()
        self.aws.start()
        self.addCleanup(self.aws.stop)
        client = boto3.client("dynamodb", region_name="eu-central-1")
        for table, key in [("accounts", "user_id"), ("subscriptions", "chain_key"), ("events", "event_id")]:
            client.create_table(TableName=table, KeySchema=[{"AttributeName": key, "KeyType": "HASH"}],
                AttributeDefinitions=[{"AttributeName": key, "AttributeType": "S"}], BillingMode="PAY_PER_REQUEST")
        from backend.billing.repository import DynamoRepository
        self.repo = DynamoRepository(client, "accounts", "subscriptions", "events", "Sandbox")
        self.account = self.repo.account("alice")
        self.snapshot = Subscription("chain", "tx", "monthly", self.account["app_account_token"], "subscribed", 2000, 1000)
        self.apple = Mock()
        self.apple.purchase.return_value = ("chain", self.account["app_account_token"])
        self.apple.reconcile.return_value = self.snapshot
        self.service = BillingService(self.repo, self.apple, clock=lambda: 1000)

    def assert_code(self, code, action):
        with self.assertRaises(CloudError) as raised:
            action()
        self.assertEqual(code, raised.exception.code)

    def test_stable_server_token(self):
        self.assertEqual(self.account, self.repo.account("alice"))
        self.assertNotEqual(self.account["app_account_token"], self.repo.account("bob")["app_account_token"])

    def test_sync_and_restore_are_idempotent_and_do_not_enable_unapproved_compute(self):
        first = self.service.sync("alice", "verified")
        second = self.service.sync("alice", "verified")
        self.assertEqual(first, second)
        self.assertEqual("active", second["subscription_access"])
        self.assertTrue(all(v is False for v in second["features"].values()))
        self.assertEqual({"chain"}, self.repo.account("alice")["chain_ids"])

    def test_foreign_purchase_is_rejected(self):
        self.assert_code("PURCHASE_ACCOUNT_CONFLICT", lambda: self.service.sync("bob", "verified"))
        self.assertIsNone(self.repo.subscription("chain"))

    def test_unique_chain_owner_cannot_be_replaced(self):
        self.service.sync("alice", "verified")
        bob = self.repo.account("bob")
        self.apple.purchase.return_value = ("chain", bob["app_account_token"])
        self.assert_code("PURCHASE_ACCOUNT_CONFLICT", lambda: self.service.sync("bob", "verified"))
        self.assertEqual("alice", self.repo.subscription("chain")["user_id"])

    def test_concurrent_reconciler_cannot_overwrite_newer_projection(self):
        self.service.sync("alice", "verified")
        old = self.repo.subscription("chain")
        self.repo.save_subscription(self.account, replace(self.snapshot, status="revoked"), old)
        self.assert_code("RECONCILIATION_CONFLICT", lambda: self.repo.save_subscription(self.account, self.snapshot, old))
        self.assertEqual("revoked", self.repo.subscription("chain")["status"])

    def test_deletion_blocks_inflight_projection_transaction(self):
        self.repo.disable_account("alice")
        self.assert_code("RECONCILIATION_CONFLICT", lambda: self.repo.save_subscription(self.account, self.snapshot, None))
        self.assertIsNone(self.repo.subscription("chain"))
        self.assert_code("ACCOUNT_DISABLED", lambda: self.service.sync("alice", "verified"))
        self.assert_code("ACCOUNT_DISABLED", lambda: self.service.status("alice"))
        self.assertEqual("deleted", self.repo.account("alice")["state"])

    def test_expiry_and_stale_projection_checked_without_notification(self):
        self.service.sync("alice", "verified")
        self.service.clock = lambda: 2000
        self.assertEqual("inactive", self.service.status("alice")["subscription_access"])
        long = replace(self.snapshot, access_expires_at=10000)
        self.repo.save_subscription(self.account, long, self.repo.subscription("chain"))
        self.service.clock = lambda: 5000
        self.assertEqual("reconciliation_required", self.service.status("alice")["subscription_access"])

    def test_old_purchase_and_out_of_order_events_use_live_state(self):
        self.service.sync("alice", "old verified transaction")
        self.apple.reconcile.return_value = replace(self.snapshot, status="revoked")
        self.apple.notification.return_value = ("event-uuid", "chain")
        self.service.webhook("old renewal")
        self.service.process_event("event-uuid")
        self.service.webhook("duplicate")
        self.service.process_event("event-uuid")
        self.assertEqual("processed", self.repo.event("event-uuid")["state"])
        self.assertEqual("inactive", self.service.status("alice")["subscription_access"])
        self.assertEqual(2, self.apple.reconcile.call_count)
        self.assertNotIn("signedPayload", self.repo.event("event-uuid"))

    def test_notification_before_sync_does_not_adopt_purchase(self):
        self.apple.notification.return_value = ("event-uuid", "chain")
        self.service.webhook("verified")
        self.service.process_event("event-uuid")
        self.assertIsNone(self.repo.subscription("chain"))
        self.assertEqual("active", self.service.sync("alice", "verified")["subscription_access"])

    def test_failed_processing_remains_pending_for_repair(self):
        self.service.sync("alice", "verified")
        self.repo.record_event("event", "chain", 1000)
        self.apple.reconcile.side_effect = TimeoutError("secret payload")
        with self.assertRaises(TimeoutError):
            self.service.process_event("event")
        self.assertEqual("pending", self.repo.event("event")["state"])
        self.apple.reconcile.side_effect = None
        self.service.process_event("event")
        self.assertEqual("processed", self.repo.event("event")["state"])

    def test_http_status_serializes_persisted_dynamodb_numbers(self):
        self.service.sync("alice", "verified")
        from backend.cloud.identity import Identity
        identity = Mock()
        identity.authenticate.return_value = Identity("alice", "apple_alice")
        with patch.object(api.runtime, "identity", return_value=identity), patch.object(api.runtime, "service", return_value=self.service):
            result = api.account_handler({"routeKey": "GET /v1/me/entitlements"}, None)
        self.assertEqual(200, result["statusCode"])
        self.assertEqual(2000, json.loads(result["body"])["access_expires_at"])

    def test_environment_partition_and_account_chain_limit(self):
        from backend.billing.repository import DynamoRepository
        production = DynamoRepository(self.repo.client, "accounts", "subscriptions", "events", "Production")
        self.service.sync("alice", "verified")
        self.assertIsNone(production.subscription("chain"))
        for i in range(1, 20):
            self.repo.save_subscription(self.account, replace(self.snapshot, chain_id=str(i)), None)
        self.assert_code("RECONCILIATION_CONFLICT", lambda: self.repo.save_subscription(self.account, replace(self.snapshot, chain_id="21"), None))
        self.assertEqual(20, len(self.repo.account("alice")["chain_ids"]))
        self.assertIsNone(self.repo.subscription("21"))


@unittest.skipUnless(boto3, "Install backend/billing/requirements-dev.txt")
class AppleGatewayTests(unittest.TestCase):
    def setUp(self):
        from backend.billing.apple import AppleGateway
        self.verifier, self.client = Mock(spec=SignedDataVerifier), Mock(spec=AppStoreServerAPIClient)
        self.gateway = AppleGateway(self.verifier, self.client, environment="Sandbox", bundle_id="app", products=["monthly"])
        self.tx = NS(environment="Sandbox", bundleId="app", productId="monthly", type="Auto-Renewable Subscription",
            inAppOwnershipType="PURCHASED", appAccountToken=uuid4(), originalTransactionId="chain", transactionId="tx",
            expiresDate=2000000, revocationDate=None)
        self.verifier.verify_and_decode_signed_transaction.return_value = self.tx
        self.item = NS(originalTransactionId="chain", signedTransactionInfo="signed", status=1, signedRenewalInfo="renewal")
        self.client.get_all_subscription_statuses.return_value = NS(environment="Sandbox", bundleId="app",
            data=[NS(lastTransactions=[self.item])])

    def test_wrong_app_product_environment_and_family_shared_rejected(self):
        for field, value in [("environment", "Production"), ("bundleId", "foreign"), ("productId", "unknown"),
                             ("inAppOwnershipType", "FAMILY_SHARED"), ("appAccountToken", None)]:
            with self.subTest(field=field):
                tx = copy.copy(self.tx)
                setattr(tx, field, value)
                self.verifier.verify_and_decode_signed_transaction.return_value = tx
                with self.assertRaises(CloudError):
                    self.gateway.purchase("signed")

    def test_real_sdk_rejects_invalid_jws(self):
        from backend.billing.apple import AppleGateway
        verifier = SignedDataVerifier([], False, Environment.SANDBOX, "app")
        gateway = AppleGateway(verifier, self.client, environment="Sandbox", bundle_id="app", products=["monthly"])
        with self.assertRaises(CloudError) as raised:
            gateway.purchase("forged.payload.signature")
        self.assertEqual("INVALID_APPLE_SIGNATURE", raised.exception.code)

    def test_certificate_service_outage_is_retryable(self):
        self.verifier.verify_and_decode_signed_transaction.side_effect = VerificationException(VerificationStatus.RETRYABLE_VERIFICATION_FAILURE)
        with self.assertRaises(CloudError) as raised:
            self.gateway.purchase("signed")
        self.assertEqual(503, raised.exception.status)

    def test_current_statuses_and_grace_expiry(self):
        self.verifier.verify_and_decode_renewal_info.return_value = NS(originalTransactionId="chain", productId="monthly", gracePeriodExpiresDate=3000000)
        for status, expected in [(1, "subscribed"), (2, "expired"), (3, "billing_retry"), (4, "grace_period"), (5, "revoked")]:
            self.item.status = status
            result = self.gateway.reconcile("chain", 1000)
            self.assertEqual(expected, result.status)
            self.assertEqual(3000 if status == 4 else 2000, result.access_expires_at)

    def test_refund_overrides_active_status(self):
        self.tx.revocationDate = 1500000
        result = self.gateway.reconcile("chain", 1000)
        self.assertEqual(("revoked", 1500), (result.status, result.access_expires_at))

    def test_grace_cannot_borrow_other_chains_renewal(self):
        self.item.status = 4
        self.verifier.verify_and_decode_renewal_info.return_value = NS(originalTransactionId="foreign", productId="monthly", gracePeriodExpiresDate=3000000)
        with self.assertRaises(CloudError):
            self.gateway.reconcile("chain", 1000)

    def test_missing_current_status_never_falls_back_to_client_transaction(self):
        self.client.get_all_subscription_statuses.return_value.data = []
        with self.assertRaises(CloudError):
            self.gateway.reconcile("chain", 1000)

    def test_notification_verifies_outer_and_nested_payloads(self):
        event_id = str(uuid4())
        self.verifier.verify_and_decode_notification.return_value = NS(notificationUUID=event_id,
            notificationType="DID_RENEW", data=NS(signedTransactionInfo="nested"))
        self.assertEqual((event_id, "chain"), self.gateway.notification("outer"))
        self.verifier.verify_and_decode_signed_transaction.assert_called_once_with("nested")
        self.verifier.verify_and_decode_signed_transaction.side_effect = VerificationException(VerificationStatus.VERIFICATION_FAILURE)
        with self.assertRaises(CloudError):
            self.gateway.notification("outer")


@unittest.skipUnless(boto3, "Install backend/billing/requirements-dev.txt")
class SignedCertificateTests(unittest.TestCase):
    """Exercise the official verifier with a local test trust root and real ES256 JWS."""
    def setUp(self):
        import base64
        import datetime
        import time
        import jwt
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID, ObjectIdentifier
        now = datetime.datetime.now(datetime.timezone.utc)
        keys = [ec.generate_private_key(ec.SECP256R1()) for _ in range(3)]
        names = [x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, n)]) for n in ("Test root", "Test intermediate", "Test leaf")]
        certs = []
        for i in range(3):
            issuer = max(0, i - 1)
            builder = (x509.CertificateBuilder().subject_name(names[i]).issuer_name(names[issuer])
                .public_key(keys[i].public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=1))
                .add_extension(x509.BasicConstraints(ca=i < 2, path_length=2-i if i < 2 else None), critical=True)
                .add_extension(x509.SubjectKeyIdentifier.from_public_key(keys[i].public_key()), critical=False)
                .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(keys[issuer].public_key()), critical=False)
                .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False, key_encipherment=False,
                    data_encipherment=False, key_agreement=False, key_cert_sign=i < 2, crl_sign=i < 2,
                    encipher_only=False, decipher_only=False), critical=True))
            if i:
                oid = "1.2.840.113635.100.6.2.1" if i == 1 else "1.2.840.113635.100.6.11.1"
                builder = builder.add_extension(x509.UnrecognizedExtension(ObjectIdentifier(oid), b"\x05\x00"), critical=False)
            certs.append(builder.sign(keys[issuer], hashes.SHA256()))
        root = certs[0].public_bytes(serialization.Encoding.DER)
        chain = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in reversed(certs)]
        self.sign = lambda payload: jwt.encode(payload, keys[2], algorithm="ES256", headers={"x5c": chain})
        self.payload = {"bundleId": "app", "environment": "Sandbox", "productId": "monthly",
            "type": "Auto-Renewable Subscription", "inAppOwnershipType": "PURCHASED",
            "appAccountToken": str(uuid4()), "originalTransactionId": "100", "transactionId": "101",
            "expiresDate": int(time.time() * 1000) + 3600000, "signedDate": int(time.time() * 1000)}
        from backend.billing.apple import AppleGateway
        self.gateway = AppleGateway(SignedDataVerifier([root], False, Environment.SANDBOX, "app"), Mock(),
            environment="Sandbox", bundle_id="app", products=["monthly"])

    def test_signed_transaction_and_notification(self):
        signed = self.sign(self.payload)
        self.assertEqual(("100", self.payload["appAccountToken"]), self.gateway.purchase(signed))
        event_id = str(uuid4())
        notification = self.sign({"notificationUUID": event_id, "notificationType": "DID_RENEW", "version": "2.0",
            "signedDate": self.payload["signedDate"], "data": {"bundleId": "app", "environment": "Sandbox", "signedTransactionInfo": signed}})
        self.assertEqual((event_id, "100"), self.gateway.notification(notification))

    def test_real_signed_wrong_bundle_environment_product_and_tampering(self):
        import base64
        for field, value in [("bundleId", "foreign"), ("environment", "Production"), ("productId", "unknown")]:
            with self.subTest(field=field), self.assertRaises(CloudError):
                self.gateway.purchase(self.sign({**self.payload, field: value}))
        parts = self.sign(self.payload).split(".")
        payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=="))
        payload["productId"] = "tampered"
        parts[1] = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
        with self.assertRaises(CloudError):
            self.gateway.purchase(".".join(parts))


class HttpAndIdentityTests(unittest.TestCase):
    def test_strict_payload_and_no_sensitive_error_details(self):
        for raw in ['[]', '{"signed_transaction":"x","user_id":"bob"}', '{}', 'invalid']:
            with self.assertRaises(CloudError):
                api.body({"body": raw}, "signed_transaction")
        response = api.safe(lambda: (_ for _ in ()).throw(RuntimeError("secret purchase data")))
        self.assertEqual(503, response["statusCode"])
        self.assertNotIn("secret", response["body"])
        self.assertEqual("no-store", response["headers"]["cache-control"])

    def test_jwt_id_token_wrong_client_scope_and_subject_rejected(self):
        cognito = Mock()
        identity = IdentityService(cognito, "issuer", "client", "paid-cloud/access")
        claims = {"iss": "issuer", "client_id": "client", "token_use": "access", "sub": "alice", "scope": "paid-cloud/access"}
        def event(value):
            return {"requestContext": {"authorizer": {"jwt": {"claims": value}}}, "headers": {"authorization": "Bearer token"}}
        for field, value in [("iss", "wrong"), ("client_id", "wrong"), ("token_use", "id"), ("scope", "openid")]:
            with self.assertRaises(CloudError):
                identity.authenticate(event({**claims, field: value}))
        cognito.get_user.return_value = {"Username": "user", "UserAttributes": [{"Name": "sub", "Value": "alice"}]}
        self.assertEqual("alice", identity.authenticate(event(claims)).user_id)
        cognito.get_user.return_value["UserAttributes"][0]["Value"] = "bob"
        with self.assertRaises(CloudError):
            identity.authenticate(event(claims))

    def test_revoked_session_fails_even_with_valid_gateway_claims(self):
        class Revoked(Exception):
            pass
        class Missing(Exception):
            pass
        cognito = Mock()
        cognito.exceptions = NS(NotAuthorizedException=Revoked, UserNotFoundException=Missing)
        cognito.get_user.side_effect = Revoked()
        identity = IdentityService(cognito, "issuer", "client", "paid-cloud/access")
        claims = {"iss": "issuer", "client_id": "client", "token_use": "access", "sub": "alice", "scope": "paid-cloud/access"}
        event = {"requestContext": {"authorizer": {"jwt": {"claims": claims}}}, "headers": {"Authorization": "Bearer revoked"}}
        with self.assertRaises(CloudError) as raised:
            identity.authenticate(event)
        self.assertEqual("SESSION_REVOKED", raised.exception.code)

    @unittest.skipUnless(boto3, "Install backend/billing/requirements-dev.txt")
    def test_repair_scan_queues_independent_work_and_next_page(self):
        service = Mock()
        service.repository.events_table = "events"
        service.repository.scan_page.return_value = ([{"event_id": "pending", "state": "pending"},
            {"event_id": "done", "state": "processed"}], {"event_id": {"S": "cursor"}})
        queue = Mock()
        message = {"messageId": "m", "body": '{"kind":"events"}'}
        with patch.object(worker.runtime, "service", return_value=service), patch("boto3.client", return_value=queue), patch.dict("os.environ", {"MAINTENANCE_QUEUE_URL": "queue"}):
            result = worker.sweep_handler({"Records": [message]}, None)
        self.assertEqual({"batchItemFailures": []}, result)
        tasks = [json.loads(c.kwargs["MessageBody"]) for c in queue.send_message.call_args_list]
        self.assertEqual([{"kind": "event", "id": "pending"}, {"kind": "events", "cursor": {"event_id": {"S": "cursor"}}}], tasks)
        service.process_event.assert_not_called()

    @unittest.skipUnless(boto3, "Install backend/billing/requirements-dev.txt")
    def test_repair_task_failure_does_not_block_another_task(self):
        service = Mock()
        service.process_event.side_effect = [RuntimeError("private"), None]
        messages = [{"messageId": str(i), "body": json.dumps({"kind": "event", "id": str(i)})} for i in range(2)]
        with patch.object(worker.runtime, "service", return_value=service), patch("boto3.client"), patch.dict("os.environ", {"MAINTENANCE_QUEUE_URL": "queue"}):
            result = worker.sweep_handler({"Records": messages}, None)
        self.assertEqual({"batchItemFailures": [{"itemIdentifier": "0"}]}, result)
        self.assertEqual(2, service.process_event.call_count)

    def test_stream_partial_failure_and_duplicate_retry(self):
        service = Mock()
        service.process_event.side_effect = [RuntimeError("private"), None]
        record = {"eventName": "INSERT", "dynamodb": {"Keys": {"event_id": {"S": "event"}}, "SequenceNumber": "123"}}
        with patch.object(worker.runtime, "service", return_value=service):
            self.assertEqual({"batchItemFailures": [{"itemIdentifier": "123"}]}, worker.handler({"Records": [record]}, None))
            self.assertEqual({"batchItemFailures": []}, worker.handler({"Records": [record]}, None))

    def test_webhook_failure_does_not_acknowledge_undurable_event(self):
        service = Mock()
        service.webhook.side_effect = RuntimeError("database unavailable")
        with patch.object(api.runtime, "service", return_value=service):
            result = api.webhook_handler({"body": '{"signedPayload":"signed"}'}, None)
        self.assertEqual(503, result["statusCode"])


if __name__ == "__main__":
    unittest.main()
