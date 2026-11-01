# Account identity and verified Apple billing

Implemented, **undeployed** component of the [paid cloud backend plan](../../docs/PAID_CLOUD_BACKEND_PLAN.md).
The full build/configuration/operations guide is [PAID_CLOUD_OPERATIONS.md](../../docs/PAID_CLOUD_OPERATIONS.md).
No normal iOS build contains cloud endpoints and all new compute admissions default disabled.

## Routes

| Route | Contract |
|---|---|
| `GET /v1/me` | Verified scoped Cognito access token; stable server `user_id`, StoreKit UUID and verified Apple subject |
| `GET /v1/products` | Configured product allowances and purchase availability, checked again before StoreKit checkout |
| `GET /v1/me/entitlements` | Subscription state, effective policy ID, available/reserved allowance and reset; never a client premium flag |
| `DELETE /v1/me` | Current session plus matching fresh native Apple code, or explicit manual-revocation fallback |
| `POST /v1/billing/apple/sync` | Exactly `{"signed_transaction":"JWS"}`; verify app/product/environment/owner, then reconcile live Apple state |
| `POST /v1/webhooks/apple` | App Store V2 `{"signedPayload":"JWS"}`; verify outer/nested signatures, durably save before acknowledgment |
| `POST /v1/webhooks/apple-identity` | Apple identity `{"payload":"JWT"}`; verify Apple JWKS, issuer/audience and supported identity event |

The [OpenAPI contract](openapi.yaml) describes the wire format. Timestamps are Unix seconds; responses
are no-store JSON. Unknown fields and bodies over 64 KiB are rejected. Public errors/logs exclude raw
SDK exceptions, signed transactions, identity tokens, source content and credentials.

Cognito JWT signatures/issuer/client/scopes are checked by API Gateway; handlers require access tokens,
live GetUser identity and the account's durable revocation floor. A scoped AdminGetUser fallback obtains
the immutable Apple subject when it is not returned by GetUser. A revoked old token cannot recover an
account merely by refreshing it: a new Apple login with a later auth_time is required. Permanent deleted
tombstones cannot reactivate. Server account tokens remain stable across devices and legitimate recovery.

Only explicit auto-renewable products with PURCHASED ownership are supported. Official Apple SDK 3.1.2
verifies reviewed roots and online certificate state. Restore cannot silently rebind an original chain to
another account. A valid old transaction/event cannot undo a later refund: synchronization always queries
current App Store status, checks grace info and conditionally updates the projection by revision. Expiry
is checked independently of delivery; stale projections require reconciliation after one hour.

The durable inbox stores minimal IDs/type/timestamps/state, not raw signed payloads or email. Its
KEYS_ONLY stream retries and scheduled paginated SQS repair deduplicate processing. Identity revocation
blocks existing Cognito sessions through a persisted floor; an older consent event cannot undo a later
fresh sign-in. Permanent Apple deletion remains permanent and also removes the mapped Cognito user.
Subscription and identity events use separate verification code and public webhook entry points.

Account deletion verifies the Apple code's subject before changing state. The durable tombstone precedes
revocation/Cognito removal, blocking in-flight paid admissions. When Apple reauthentication/revocation is
unavailable, an explicit fallback still deletes cloud data and directs the user to manual Apple revocation.
Deletion does not cancel App Store billing; the app links subscription management. Minimal chain ownership
records remain for conflict/recovery protection; local books, dictionary and personal key stay independent.

## Verification and configuration

Use the commands in the [runbook](../../docs/PAID_CLOUD_OPERATIONS.md). Tests exercise real local
cryptographic certificate/JWS and RSA identity signatures, wrong environments/subjects, duplicate and
out-of-order events, concurrent projections, expiry/grace/refunds, deletion races, manual deletion,
revoked sessions and fresh recovery. AWS DynamoDB Local also verifies real transaction behavior;
Moto isolates the other service dependencies. No real purchase or provider key is used by tests.

Foundation, billing, translation and optional paid alignment are separate stacks under the
`infra/alignment/bin/cloud.ts` entry point. Foundation/billing/translation synthesize without an alignment
image. Separate roles keep public webhooks away from credentials, account deletion away from provider
keys, inference away from alignment media and alignment workers away from billing/provider secrets.
All publish/configure/deploy/real-sandbox steps remain external acceptance gates, not completed work.
