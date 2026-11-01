"""Official Apple SDK adapter. Only live reconciled state grants access."""
from uuid import UUID
from backend.cloud.errors import CloudError
from .domain import STATUSES, Subscription, canonical_token


def verified_call(action, signed):
    from appstoreserverlibrary.signed_data_verifier import VerificationException, VerificationStatus
    try:
        return action(signed)
    except VerificationException as error:
        if error.status == VerificationStatus.RETRYABLE_VERIFICATION_FAILURE:
            raise CloudError("APPLE_VERIFICATION_UNAVAILABLE", 503) from None
        raise CloudError("INVALID_APPLE_SIGNATURE", 400) from None


def enum_value(value):
    return getattr(value, "value", value)


class AppleGateway:
    def __init__(self, verifier, client, *, environment, bundle_id, products):
        self.verifier, self.client = verifier, client
        self.environment, self.bundle_id, self.products = environment, bundle_id, frozenset(products)

    def _transaction(self, signed):
        tx = verified_call(self.verifier.verify_and_decode_signed_transaction, signed)
        if enum_value(tx.environment) != self.environment or tx.bundleId != self.bundle_id:
            raise CloudError("WRONG_APPLE_APPLICATION", 400)
        if tx.productId not in self.products or enum_value(tx.type) != "Auto-Renewable Subscription":
            raise CloudError("UNSUPPORTED_PRODUCT", 400)
        if enum_value(tx.inAppOwnershipType) != "PURCHASED":
            raise CloudError("UNSUPPORTED_OWNERSHIP", 409)
        if not tx.originalTransactionId or not tx.transactionId or not tx.expiresDate:
            raise CloudError("INVALID_TRANSACTION", 400)
        canonical_token(tx.appAccountToken)
        return tx

    def purchase(self, signed):
        tx = self._transaction(signed)
        return str(tx.originalTransactionId), canonical_token(tx.appAccountToken)

    def notification(self, signed):
        event = verified_call(self.verifier.verify_and_decode_notification, signed)
        try:
            event_id = str(UUID(str(event.notificationUUID)))
        except (ValueError, TypeError, AttributeError):
            raise CloudError("INVALID_NOTIFICATION", 400) from None
        if enum_value(event.notificationType) == "TEST":
            return event_id, None
        if not event.data or not event.data.signedTransactionInfo:
            raise CloudError("UNSUPPORTED_NOTIFICATION", 400)
        # Nested signatures are independently verified. Never apply arrival-order state.
        tx = self._transaction(event.data.signedTransactionInfo)
        return event_id, str(tx.originalTransactionId)

    def reconcile(self, chain_id, now):
        response = self.client.get_all_subscription_statuses(chain_id)
        if enum_value(response.environment) != self.environment or response.bundleId != self.bundle_id:
            raise CloudError("WRONG_APPLE_APPLICATION", 400)
        matches = [item for group in (response.data or []) for item in (group.lastTransactions or [])
                   if str(item.originalTransactionId) == chain_id]
        if len(matches) != 1:
            raise CloudError("APPLE_STATUS_UNAVAILABLE", 503)
        item = matches[0]
        tx = self._transaction(item.signedTransactionInfo)
        if str(tx.originalTransactionId) != chain_id:
            raise CloudError("INVALID_TRANSACTION", 400)
        status = STATUSES.get(enum_value(item.status))
        if status is None:
            raise CloudError("APPLE_STATUS_UNAVAILABLE", 503)
        expiry = tx.expiresDate // 1000
        if status == "grace_period":
            if not item.signedRenewalInfo:
                raise CloudError("APPLE_STATUS_UNAVAILABLE", 503)
            renewal = verified_call(self.verifier.verify_and_decode_renewal_info, item.signedRenewalInfo)
            if (str(renewal.originalTransactionId) != chain_id
                    or renewal.productId != tx.productId or not renewal.gracePeriodExpiresDate):
                raise CloudError("APPLE_STATUS_UNAVAILABLE", 503)
            expiry = renewal.gracePeriodExpiresDate // 1000
        if tx.revocationDate is not None:
            status, expiry = "revoked", min(expiry, tx.revocationDate // 1000)
        return Subscription(chain_id, str(tx.transactionId), tx.productId,
                            canonical_token(tx.appAccountToken), status, expiry, now)
