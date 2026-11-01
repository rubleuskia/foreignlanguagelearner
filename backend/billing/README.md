# Paid cloud foundation and Apple billing

First implementation slice of [the paid backend plan](../../docs/PAID_CLOUD_BACKEND_PLAN.md).
**Not deployed. No iOS purchase UI, tariffs, quota or inference service is enabled.**

## Implemented contract

| Route | Authorization | Contract |
|---|---|---|
| `GET /v1/me` | Cognito access token, `paid-cloud/access` scope | Stable server-generated `app_account_token` UUID for StoreKit purchases |
| `GET /v1/me/entitlements` | Same | Subscription projection, expiry/freshness and separately disabled compute features |
| `DELETE /v1/me` | Same, live session | Tombstone account first; remove Cognito user; retain minimal purchase ownership |
| `POST /v1/billing/apple/sync` | Same | Exactly `{"signed_transaction":"JWS"}`; verify, reconcile live Apple status and atomically bind chain |
| `POST /v1/webhooks/apple` | Apple JWS, no user JWT | Exactly Apple's `{"signedPayload":"JWS"}`; verify outer/nested JWS and persist event before HTTP 200 |

The machine-readable contract is [openapi.yaml](openapi.yaml). Timestamps are Unix seconds.
All responses use `Cache-Control: no-store`; JSON errors contain a stable code and no raw SDK error.
`schema_version: 1` applies to account and entitlement responses. Bodies are capped at 64 KiB;
unknown fields are rejected. API Gateway validates signature, issuer, audience and route scope;
the handler additionally requires an access token and confirms the session/subject with Cognito
GetUser, which also rejects [revoked tokens](https://docs.aws.amazon.com/cognito/latest/developerguide/token-revocation.html). Login uses the Cognito authorization-code flow with **PKCE S256 in the future native
client**, Sign in with Apple only, no client secret, 15-minute access tokens and revocable refresh
tokens. The native app must request `openid email aws.cognito.signin.user.admin paid-cloud/access`.

`appAccountToken` is association data, never authentication. Restore requires the original app
account. Missing bindings, foreign tokens and Family Sharing purchases fail closed. No automatic
legacy adoption or purchase transfer is implemented; return `PURCHASE_ACCOUNT_CONFLICT` and use
a future authenticated support workflow. A fresh installation on a second device signs into the
same app account and receives the same token.

Apple's official Python SDK verifies certificate trust, bundle, environment and signatures with
online certificate checks enabled. Only explicit auto-renewable products with PURCHASED ownership
are supported. Every purchase sync and lifecycle event queries current App Store Server API status;
a valid old JWS never directly grants access. Grace access requires matching signed renewal info.
Turning off auto-renewal preserves active paid access until expiry. Refund/revocation removes it.
Sandbox and production have separate stacks/tables/credentials and fixed Apple environments.

## Storage and recovery

- Foundation owns retained, encrypted, point-in-time-recoverable Accounts and Subscriptions tables.
  No table uses alignment TTL. Each account holds a bounded set of at most 20 subscription chains.
- Billing owns a retained event inbox with a KEYS_ONLY DynamoDB stream. It stores event UUID, chain,
  processing state and timestamps; **no raw signed payload, purchase receipt, email or source text**.
- The stream dispatches verified inbox inserts. Duplicate events do not reset processed state.
  Failed records retry individually and have an SQS dead-letter path. An orphan event before first
  sync is processed without adoption; first authenticated sync reconciles current state.
- Chain ownership, account state/token and subscription revision are checked in one DynamoDB
  transaction. Concurrent/stale projections conflict rather than overwrite; retry the entire
  reconciliation, including the live Apple query. `RECONCILIATION_CONFLICT` is retryable with backoff.
- Every five minutes, paginated maintenance walks queue independent pending-event and stale-chain
  tasks. Standard SQS duplicates are harmless. Chain tasks skip already fresh records. Each task
  has bounded retries and a dead-letter path, so one bad purchase cannot block later scan pages.
- Reconcile projections after 30 minutes; after 60 minutes an otherwise unexpired projection returns
  `subscription_access: reconciliation_required`. Expiry is checked on every read/admission.
  This is a development freshness setting, not an approved production product policy.
- `features` are all false and `allowance` is null even when `subscription_access` is active. Future
  compute admission must require a fresh projection **and** a configured allowance/reservation policy.
- Deletion first persists a tombstone so an in-flight transaction cannot regrant access. If Cognito
  removal fails, retry DELETE with the same live session. Deletion does not cancel Apple billing;
  the response links subscription management. Purchase ownership remains to prevent reassignment.

No source text or provider key enters this component. There is no translation or alignment route,
provider credential permission, NAT, worker image or Fargate dependency. Existing BYOK/local app
workflows and anonymous development alignment are unchanged.

## Verification

```sh
python3 -m venv /tmp/fll-cloud-tests
/tmp/fll-cloud-tests/bin/pip install --require-hashes -r backend/billing/requirements.lock
/tmp/fll-cloud-tests/bin/pip install -r backend/billing/requirements-dev.txt
/tmp/fll-cloud-tests/bin/python -m unittest discover -s backend -p 'test_*.py' -v
cd infra/alignment
npm ci
npm test
```

The billing tests use Moto's DynamoDB emulator and the official Apple SDK/model interface. They
cover transaction conflicts, foreign-account restore, deletion races, duplicate/out-of-order events,
refunds, grace, stale/expired access, malformed JWS, strict input and partial failures. They do not
replace live sandbox signature/certificate, Cognito revocation or Apple renewal/refund tests.
CDK assertions synthesize both dev and prod assemblies without an alignment image and check route
scopes, retained tables, retries and webhook IAM isolation. CI installs billing dependencies.

## Build and synthesize (does not deploy)

1. Obtain reviewed DER Apple roots from [Apple PKI](https://www.apple.com/certificateauthority/).
   Review their SHA-256 fingerprints independently. Do not use certificate roots supplied by a client.
2. Build a Linux x86_64 Python 3.12 asset, including hash-locked dependencies:

```sh
python3 scripts/build-cloud.py --apple-roots /absolute/path/to/reviewed-roots \
  --root-sha256 REVIEWED_DER_SHA256 --output /tmp/fll-cloud-asset
```

Repeat `--root-sha256` for every packaged `.cer`. Output must be a fresh directory. The script never
copies private keys or the repository's other backend. The supplied fingerprints remain an operator
trust decision; the build verifies consistency with that reviewed list.

3. Provision separate Secrets Manager secrets for the selected environment. Apple login secret:
   `{"private_key":"PEM"}`. App Store Server API In-App Purchase key:
   `{"private_key":"PEM","key_id":"...","issuer_id":"..."}`. These are different integrations;
   never put actual values in CDK context, source control or a command line.
4. Register Apple's Services ID, redirect `https://LOGIN_DOMAIN/oauth2/idpresponse`, native callback
   URL and explicit subscription product IDs. The Services ID is the login client ID, not the app's
   bundle ID. Configure only the matching environment's Apple notification URL.
5. Synthesize from `infra/alignment`:

```sh
npm run synth:cloud -- \
  -c stage=dev -c cloudAsset=/tmp/fll-cloud-asset \
  -c appleClientId=YOUR_APPLE_SERVICES_ID -c appleTeamId=YOUR_TEAM_ID \
  -c appleSignInKeyId=YOUR_LOGIN_KEY_ID \
  -c appleSignInSecretArn=YOUR_COMPLETE_LOGIN_SECRET_ARN \
  -c appleApiSecretArn=YOUR_COMPLETE_APP_STORE_SECRET_ARN \
  -c callbackUrl=fll://auth -c loginDomainPrefix=YOUR_UNIQUE_DEV_PREFIX \
  -c appleProducts=YOUR_SANDBOX_PRODUCT_ID
```

Prod additionally requires `-c appAppleId=NUMERIC_APP_ID`; use separate AWS accounts and credentials.
The default `npm run synth` still targets the gated alignment stack. No deployment is performed by
CI or these commands. The same CDK package hosts independent entry points, avoiding lockfile drift.
Rebuild and redeploy the asset after SDK/root updates; update requirements.lock with reviewed
`pip-compile --generate-hashes --reuse-hashes --strip-extras --output-file backend/billing/requirements.lock backend/billing/requirements.txt`.

## Operations and remaining launch gates

Subscribe an operator to the output OperationsAlarms SNS topic. Alerts cover API 5xx responses, account/worker errors,
worker throttling, stream lag, maintenance backlog age and dead letters; inspect failures by safe IDs, not payloads. Replay a
stream dead-letter key by enqueueing `{"kind":"event","id":"UUID"}` on the maintenance queue;
replay a maintenance task using its original body. Both re-read authoritative state. Periodic walks
also repair missing notifications and dropped stream deliveries. Rotate the App Store API secret
and login key independently. Requests reload API credentials on each invocation.

Production remains gated on real Cognito/Apple sandbox tests, approved products/allowances/reset and
failure policies, iOS login/StoreKit recovery UX, native PKCE/callback validation, Apple authorization
revocation on account deletion, a support/conflict workflow, operator alarm subscriptions and a
reviewed metadata/backup retention policy. Current retained tables intentionally provide no automatic
billing-record erasure before that policy is chosen. The paginated maintenance scan is bounded per
invocation and intended for the initial small deployment; evaluate indexed due-work scheduling and
backlog age at production scale. No production-readiness claim accompanies the implementation.
