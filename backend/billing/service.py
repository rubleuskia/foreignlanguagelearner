"""Account binding and optimistic reconciliation shared by HTTP and background work."""
import time
from backend.cloud.errors import CloudError
from .domain import canonical_token, entitlement


class BillingService:
    def __init__(self, repository, apple, *, clock=time.time, freshness_seconds=3600, allowance_projection=None, delete_identity=None):
        self.repository, self.apple, self.clock = repository, apple, clock
        self.freshness_seconds = freshness_seconds
        self.allowance_projection = allowance_projection
        self.delete_identity = delete_identity

    def account(self, user_id):
        account = self.repository.account(user_id)
        if account["state"] != "active":
            raise CloudError("ACCOUNT_DISABLED", 403)
        return account

    def status(self, user_id):
        account = self.account(user_id)
        subscriptions = self.repository.subscriptions(account)
        view = entitlement(account, subscriptions, int(self.clock()), self.freshness_seconds)
        return self.allowance_projection(view, account, subscriptions, int(self.clock())) if self.allowance_projection else view

    def sync(self, user_id, signed):
        account = self.account(user_id)
        chain_id, token = self.apple.purchase(signed)
        if canonical_token(account["app_account_token"]) != token:
            raise CloudError("PURCHASE_ACCOUNT_CONFLICT", 409)
        self.reconcile(chain_id, user_id, account)
        return self.status(user_id)

    def reconcile(self, chain_id, user_id=None, account=None):
        previous = self.repository.subscription(chain_id)
        if previous:
            if user_id is not None and previous["user_id"] != user_id:
                raise CloudError("PURCHASE_ACCOUNT_CONFLICT", 409)
            user_id = previous["user_id"]
            account = self.repository.account(user_id)
        if user_id is None or account is None:
            # Notification before first sync: do not adopt purchases by guessing identity.
            # First authenticated sync always fetches current Apple state.
            return
        if account["state"] != "active":
            return
        snapshot = self.apple.reconcile(chain_id, int(self.clock()))
        if snapshot.app_account_token != canonical_token(account["app_account_token"]):
            raise CloudError("PURCHASE_ACCOUNT_CONFLICT", 409)
        # Concurrent reconcilers cannot let a slower, older response overwrite a newer one.
        # A conflict retries the complete live Apple query, not just the database write.
        self.repository.save_subscription(account, snapshot, previous)

    def webhook(self, signed):
        event_id, chain_id = self.apple.notification(signed)
        self.repository.record_event(event_id, chain_id, int(self.clock()))
        return {"accepted": True}

    def process_event(self, event_id):
        event = self.repository.event(event_id)
        if not event or event["state"] == "processed":
            return
        if event.get('kind') == 'apple_identity':
            for username in self.repository.apply_identity_event(event, int(self.clock())):
                if self.delete_identity: self.delete_identity(username)
        elif event.get("chain_id"):
            self.reconcile(event["chain_id"])
        self.repository.finish_event(event_id, int(self.clock()))
