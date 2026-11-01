# Account-backed cloud operations (undeployed)

This implements the code and offline validation for the [paid cloud plan](PAID_CLOUD_BACKEND_PLAN.md).
The [local control panel](CLOUD_CONTROL.md) adds production status, verified-tag prepare/deploy/rollback
and opt-in real API probes. It starts with no AWS configuration and never deploys automatically.
No AWS deployment, Apple product creation, TestFlight upload, production purchase, paid inference or
alignment benchmark approval is performed. Normal app builds have no cloud endpoint. Local reading,
import, saved dictionaries, Apple Translation and the explicit personal-key mode remain available.

## Configuration and product contract

- Recoverable identity is Cognito with Sign in with Apple. Native login uses authorization-code +
  PKCE S256, a random state and exact callback validation. Tokens are in a device-only Keychain item.
  Refresh coalesces across callers; sign-out/account changes invalidate pending results and refreshes.
- Register the native App ID for Sign in with Apple, group its Services ID with the same primary App
  ID, and register Cognito's `https://LOGIN_DOMAIN/oauth2/idpresponse` plus `fll://auth`. The signing
  profile must include the new Sign in with Apple entitlement. Validate grouping on real devices.
- Register **both** notifications: App Store V2 → `/v1/webhooks/apple`; Sign in with Apple identity
  events → `/v1/webhooks/apple-identity`. They use different verification protocols. Configure the
  appropriate primary app / Services ID and environment endpoints in Apple's portals.
- The server verifies the user session live with Cognito and checks a durable session-revocation
  floor. Apple consent revocation blocks older sessions even after a later account recovery. A fresh
  Apple sign-in recovers the same account UUID/token; permanent account deletion cannot reactivate it.
  Native credential-state checks run on foreground and credential-revoked notifications too.
- Prices, localized descriptions and billing periods come from StoreKit. No prices or product IDs
  are invented in source. Family Sharing and legacy purchases without a valid account binding fail
  closed. Product allowlists, dev/prod credentials, accounts and provider projects must be separate. The authenticated `/v1/products` catalogue publishes configured allowances and purchase availability; the app preflights it before checkout and never offers a disabled/unconfigured service.
- An explicit operator policy maps each approved Apple product to `translations` and `alignments`
  allowances. Empty `products` disables benefits. [`policy.example.json`](../backend/cloud/policy.example.json)
  is an **inactive example**, not an approved tariff or operating budget. The small global limits in
  that example never grant access by themselves. Supply reviewed values before enabling admissions.
- Allowances reset on the first of each UTC calendar month, including annual plans. A successful
  context analysis or word explanation consumes one translation unit; an alignment consumes one job
  unit, not client-declared audio minutes. Trial transactions use the configured product allowance;
  do not configure trial offers until this behavior and spend are approved. No proration is promised.
- All active products share the account's monthly feature counter; the highest eligible allowance
  applies. Upgrade, downgrade, renew and policy-version changes never reset usage already consumed. Do not remove or reduce promised active-product benefits before their paid periods end.
- Reserve before admitting; release on failure, uncertain outcome, expiry or pre-dispatch cancellation.
  Settle only a valid successful result once, in its original period. Global daily admission and
  frequency counters are **not refunded**, bounding repeated failure costs. In-flight reservations
  count against available allowance and account/global concurrency. Accepted alignment uploads also
  hold a reservation until completion, cancellation or the existing 24-hour upload deadline.
- Effective policy IDs hash the product/limit/model configuration, both server prompts and schemas.
  Compatible admitted work continues through kill switches/subscription expiry. An accepted translation
  whose effective policy is no longer available is cancelled/refunded before submission, rather than
  silently running changed prompts. Already running work can finish using its original invocation.

## Request execution, ownership and recovery

`POST /v1/context-analyses` and `POST /v1/word-explanations` accept schema 1 and a UUID
`Idempotency-Key`. Inputs contain only a bounded selected excerpt, its exact UTF-16 range, one of
`en/fr/es/de/it/pl`, Russian target, and an ordered word subsequence or lemma. Limits are 256 UTF-16
units selected and 1,400 context. No provider key, URL, arbitrary model, tools or custom prompt is accepted.

A single DynamoDB transaction checks account/subscription revision, freshness, expiry and counters,
reserves usage, writes metadata and writes temporary input. The KEYS_ONLY metadata stream dispatches
only request IDs to SQS. Scheduled paginated maintenance repairs lost dispatch independently of the
stream. Conditional claim allows one external submission; duplicate messages cannot submit again.

A claim is a conservative submission boundary. A process death immediately after claim can become
`outcome_unknown` even if no external cost occurred. A lost provider response or abandoned running
lease never permits a second inference. The watchdog releases the user's allowance while retaining
unknown-cost metadata. There is no claim of exactly-once external inference. HTTP submission has no
automatic provider retry, arbitrary tools or redirects. Responses use strict schemas and `store:false`;
this does **not** promise zero retention by OpenAI. Token counts are kept separately from allowance.

Owner-only GET `/v1/requests/{id}` returns state/result. GET `/v1/requests/by-key/{key}` recovers a lost
POST response after relaunch without storing input in the local request ledger. Cancellation can stop
accepted work; cancelling UI waiting after dispatch does not cancel provider cost. The client persists
its key before POST, polls with bounded backoff and reuses unresolved keys even if policy changes.
Known successful caches separate account, environment, operation and effective policy. The Cloud
requests screen resumes, cancels or explicitly permits a fresh request; uncertain outcomes never
create an automatic new billable operation. A corrupt ledger fails closed before a new key is created.
Personal-key/custom-prompt caches are separate; a subscription error never spends a personal key.
Listening-choice generation currently requires explicit personal-key mode and is not a subscription benefit.

## Purchases, deletion and support

The server assigns the stable StoreKit `appAccountToken`. The native client distinguishes cancellation,
pending Apple approval and verified success, listens for updates from app launch, retries unfinished
transactions and restores purchases. Finish occurs only after authoritative server synchronization.
An activation outage keeps the purchase recoverable and suppresses another purchase invitation.
Sandbox/Xcode transactions cannot activate production service. Local StoreKit test purchases are not
accepted by the real server; injected signed fixtures/transport tests exercise offline recovery.

The server verifies App Store signatures with Apple's official library, expected app/environment,
product allowlist and unique subscription-chain owner. Every sync/event reconciles current Apple
status, including grace/refund/revocation. A signed old transaction cannot regrant access. Stale
projections stop admissions after one hour; background reconciliation starts after 30 minutes.

DELETE `/v1/me` accepts either a fresh native `authorization_code` or an explicit
`{"manual_revocation":true}`. Native Apple proof must match the verified Cognito Apple subject. The
account tombstone is durable before revocation/removal, preventing concurrent admissions. If Apple
revocation is unavailable, cloud data deletion still proceeds and the app directs the user to Apple's
manual revocation instructions. Retrying a failed Cognito removal is safe while its session still
exists. The app clears its cloud Keychain session; local books/dictionary and personal key remain
independent. Deleting the cloud account does not cancel Apple billing; Settings links management.

Minimal ownership/tombstone records persist to prevent silent purchase reassignment. For a conflict,
ask the user to sign into the original app account and restore on that account; provide the configured
support link. Support must verify account control and current Apple state before any reviewed recovery.
Do not copy chain owners/appAccountTokens in DynamoDB or silently adopt a legacy/foreign purchase.
Account restoration should recover the original identity/records from reviewed backups; transfer of
ownership, Family Sharing and merging two app accounts are deliberately not automatic product features.

## Retention, deletion and operations

- Temporary translation input is removed transactionally at terminal settlement. Results are readable
  for 24 hours from successful completion; input has a 10-minute pending deadline and claimed work a
  120-second deadline. A watchdog closes abandoned work without resubmission.
- Temporary content has **no PITR backup**. Independent paginated content scans issue DeleteItem
  after expiry even if metadata is missing; TTL is a fallback. Exclude its
  `DataClass=temporary-content-no-backups` tag from organization-wide AWS Backup policies before launch.
- Request/usage/event metadata is retained 90 days; application access expiry and scheduled event
  pruning precede TTL where applicable. Paid alignment metadata/idempotency is 90 days, while the
  existing anonymous test metadata stays seven days. Minimal account/chain ownership and revocation
  floors persist for recovery/conflict protection. Review these choices and AWS-managed backup retention
  before production; metadata PITR can retain earlier versions for its AWS recovery window.
- Alignment keeps its independent S3 input/output cleanup, pinned versions, manifest finalization,
  one-attempt worker, upload limits and global 20 creates / 10 starts / 2 running caps. Paid cleanup
  persists scan progress; deleted owners trigger cancellation and deletion of retained artifacts.
  Backlog and scan throughput must be measured before opening alignment; service/TTL/lifecycle cleanup
  is asynchronous and application expiry is enforced independently.
- Logs contain safe operation/request IDs and error categories, never selected text, results, raw
  purchase JWS, identity tokens, authorization headers or provider keys. Queues and dead letters carry
  IDs/maintenance cursors, not input. All temporary content remains private and encrypted.
- Subscribe an operator to the output OperationsAlarms SNS topic. Alarms cover API 5xx, worker errors,
  throttling, stream lag, maintenance/inference backlog age and dead letters. Separate switches
  `ACCEPT_TRANSLATIONS` and `ACCEPT_ALIGNMENTS` stop new work while preserving billing and retrieval.
- Replay a billing event by enqueueing `{"kind":"event","id":"UUID"}` to billing maintenance; replay
  a translation with `{"id":"REQUEST_UUID"}` to inference. State guards, not the queue, decide whether
  it can execute. Never reset a running/unknown request to accepted to force retry.
- Incident/rollback: stop admissions, retain compatible code/policy for in-flight work, drain or cancel
  accepted work, inspect safe IDs and token/unknown-cost metadata. Before any PITR recovery, pause
  workers and reconcile reservations/counters across tables; never lower usage or reset daily caps
  merely to unblock a restore. Content is not restored from backup. Do not remove stacks before
  scheduled/S3 cleanup has drained. Budget alarms notify; admission counters and switches stop work.

## Build and synthesize only

```sh
python3 -m venv /tmp/fll-cloud
/tmp/fll-cloud/bin/pip install --require-hashes -r backend/billing/requirements.lock
/tmp/fll-cloud/bin/pip install -r backend/billing/requirements-dev.txt
PYTHON=/tmp/fll-cloud/bin/python bash scripts/test-cloud-contracts.sh
cd infra/alignment && npm ci && npm test
```

The script uses Java 17 and AWS DynamoDB Local in a temporary directory (no AWS account), including
real concurrent transaction tests. Moto covers other isolated AWS/Apple failure paths. No live purchase
or inference credentials are needed. CI runs these checks and the existing aligner regression suite.

Obtain reviewed DER roots from [Apple PKI](https://www.apple.com/certificateauthority/). Build a fresh
Linux Python 3.12 x86_64 Lambda asset, checking independently reviewed SHA-256 fingerprints:

```sh
python3 scripts/build-cloud.py --apple-roots /absolute/path/to/reviewed-roots \
  --root-sha256 REVIEWED_DER_SHA256 --output /tmp/fll-cloud-asset
```

Repeat the fingerprint flag for all packaged `.cer` files. The artifact vendors hash-locked Apple and
AWS SDK dependencies and includes every server module; it does not contain private keys.

Secrets Manager configuration, separately for each environment:

| Secret | JSON fields | Readers |
|---|---|---|
| Apple Sign in key | `private_key` | Cognito IdP configuration, dedicated account-deletion Lambda |
| App Store In-App Purchase key | `private_key`, `key_id`, `issuer_id` | Billing sync/reconciliation workers |
| Dedicated OpenAI project key | `api_key` | Translation inference Lambda only |

Keep actual secret values out of source, CDK context, shell history and chat. Secret ARNs and public
Apple team/key IDs belong to environment configuration. Synthesize without an alignment image:

```sh
cd infra/alignment
npm run synth:cloud -- \
  -c stage=dev -c cloudAsset=/tmp/fll-cloud-asset \
  -c appleClientId=YOUR_GROUPED_APPLE_SERVICES_ID -c appleTeamId=YOUR_TEAM_ID \
  -c appleSignInKeyId=YOUR_LOGIN_KEY_ID -c appleSignInSecretArn=COMPLETE_LOGIN_SECRET_ARN \
  -c appleApiSecretArn=COMPLETE_APP_STORE_SECRET_ARN -c openaiSecretArn=COMPLETE_PROVIDER_SECRET_ARN \
  -c callbackUrl=fll://auth -c loginDomainPrefix=YOUR_UNIQUE_DEV_PREFIX \
  -c appleProducts=YOUR_PRODUCT_ID -c cloudPolicy=/absolute/path/to/reviewed-policy.json
```

`cloudComponents=billing` omits translation infrastructure. Admissions default false; only an explicitly
reviewed product policy plus `acceptTranslations=true` enables translations. Production additionally
requires a numeric `appAppleId` and production credentials/products. Use separate AWS accounts/projects.
These commands synthesize local templates only. No deployment or publishing command is run here.

After a future authorized environment exists, generate the ignored public iOS resource from its CDK
outputs; never reuse sandbox endpoints in a production build:

```sh
python3 scripts/configure-cloud-ios.py --outputs /path/to/cdk-outputs.json --stage dev \
  --products YOUR_PRODUCT_ID --privacy-url https://YOUR_HOST/privacy \
  --terms-url https://YOUR_HOST/terms --support-url https://YOUR_HOST/support
xcodegen generate
```

`App/Configuration/CloudConfiguration.plist` is ignored and absent by default. It contains public URLs,
client/product IDs and environment, no credentials. Required policy/support URLs, HTTPS, callback and
product validation fail closed. Rebuild after adding it. Provider mode remains a separate explicit choice.

## Paid alignment gate

The optional `paidAlignment=true` assembly also requires `workerRepositoryName`, immutable
`workerImageDigest` and `alignmentBenchmarkReport` path. The report must match that exact image and
contain `maxJobCostUsd` plus each language's `qualityAccepted`, finite positive `runtimeSeconds` (≤13,500),
`peakMemoryMiB` (≤8,192) and nonnegative `costUsd` within the approved per-job cap. Record actual
six-language audio measurements/review in [ALIGNMENT_BENCHMARKS.md](ALIGNMENT_BENCHMARKS.md) before
providing such a report. Synthetic infrastructure-test values are not a benchmark approval.

Paid alignment attaches only scoped `/v2/alignments` routes to the authenticated API; no anonymous
`/v1` API is created in that stack. Owners are server-bound, old anonymous jobs cannot be adopted,
and the stored authority namespace cannot authorize a capability request. Access is checked on create,
upload renewal and start; quota creation, durable start and terminal settlement remain transactional.
Already started work can finish after expiry and its owner can retrieve results during normal retention.
Alignment workers have no billing/provider credential permission and translation workers have no media access.

## External acceptance still required (not completed by code or mocks)

Before TestFlight: configure Apple/Cognito callback grouping, entitlement/profile and both real webhook
URLs; exercise sandbox purchase, pending approval, interruption, cross-device restore, foreign account,
renewal, grace, refund, consent revocation, permanent identity deletion and lost notification recovery.
Verify foreground/reauthentication on physical devices. Run the deployed end-to-end provider path with
bounded development spend, inspect privacy-safe logs and test operator alarms/kill switches/dead letters.

Before production: approve real products, prices/offers, allowance/failure/reset policy, operating budget,
privacy/terms/support pages, retention/backups, support recovery procedure and Apple app/IAP review.
Verify separate production provider credentials and reject sandbox/Xcode proofs. Measure six-language
alignment quality/runtime/memory/cost before enabling its independent gate. No deployment, Apple
submission, TestFlight upload or production-readiness claim accompanies this PR.

Primary contracts: [OpenAI structured output](https://developers.openai.com/api/docs/guides/structured-outputs),
[Apple identity notifications](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts),
[Apple deletion/revocation](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple),
[Cognito token revocation](https://docs.aws.amazon.com/cognito/latest/developerguide/token-revocation.html).
