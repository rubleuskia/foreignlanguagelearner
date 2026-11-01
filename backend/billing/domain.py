"""Verified billing projection. No prices or unapproved allowances are implicit."""
from dataclasses import asdict, dataclass
from uuid import UUID
from backend.cloud.errors import CloudError


STATUSES = {1: "subscribed", 2: "expired", 3: "billing_retry", 4: "grace_period", 5: "revoked"}


def canonical_token(value):
    try:
        return str(UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        raise CloudError("ACCOUNT_BINDING_REQUIRED", 409) from None


@dataclass(frozen=True)
class Subscription:
    chain_id: str
    transaction_id: str
    product_id: str
    app_account_token: str
    status: str
    access_expires_at: int
    verified_at: int

    def record(self):
        return asdict(self)


def entitlement(account, subscriptions, now, freshness_seconds):
    if account.get("state") != "active":
        raise CloudError("ACCOUNT_DISABLED", 403)
    # Expiry is checked on each read/admission, independently of notification delivery.
    accessible = [s for s in subscriptions if s["status"] in {"subscribed", "grace_period"}
                  and s["access_expires_at"] > now]
    fresh = [s for s in accessible if s["verified_at"] + freshness_seconds > now]
    state = "active" if fresh else "reconciliation_required" if accessible else "inactive"
    return {
        "schema_version": 1,
        "subscription_access": state,
        "access_expires_at": max((int(s["access_expires_at"]) for s in fresh), default=None),
        "subscriptions": [{k: int(s[k]) if k in {"access_expires_at", "verified_at"} else s[k] for k in ("product_id", "status", "access_expires_at", "verified_at")}
                          for s in subscriptions],
        # Subscription verification is deliberately separate from spending policy.
        "features": {"context_analysis": False, "word_explanation": False, "alignment": False},
        "allowance": None,
        "policy_version": "billing-foundation-v1",
    }
