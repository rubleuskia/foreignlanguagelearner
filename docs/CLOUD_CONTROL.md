# Local AWS production control

The [two-stage rollout plan](CLOUD_ROLLOUT.md) now targets a private operator backend before Apple
and subscriptions. The operator assembly/dashboard mode is implemented: see [first-stage publication](OPERATOR_CLOUD.md).
Choose the first stage in settings; no Apple parameters are required. Older verified tags do not
contain that assembly and are filtered out. The subscription-specific procedure below applies to
the second stage. Do not fill Apple fields with dummy values.

From the repository root, run `bash scripts/cloud-control.sh` and open **http://127.0.0.1:8767**.
Python 3.12+, Node/npm, Git and authenticated GitHub CLI (`gh auth login`) are required. The launcher
creates an ignored local environment with the existing hash-locked dependencies. It never deploys on
startup. The loopback-only service is for a trusted local OS user; do not expose it through a proxy.

## Connect AWS

An AWS login email is **not** the account ID. Copy the 12-digit ID from the AWS console account menu.
In **Настройка**, enter it and a local AWS SDK profile name. Stockholm (`eu-north-1`) is the region
supported by the current stacks. For IAM Identity Center, configure/login outside the panel:

```sh
aws configure sso --profile fll-prod
aws sso login --profile fll-prod
```

Use the organization's existing SSO start URL/role. Existing non-SSO SDK profiles also work. The panel
does not collect passwords, MFA codes, AWS keys, Apple private keys or OpenAI keys. Expired SSO login
must be renewed locally. STS must match the configured account before any inspection or deployment.
Both SDK and CDK use the named profile; ambient static/session credentials cannot override it.

Read-only status requires STS identity, CloudFormation DescribeStacks/GetTemplate/ListStackResources
for the four named prod stacks and CloudWatch DescribeAlarms. CDK diff needs normal CDK read access.
Deployment needs separately approved CDK deployment/file-publishing roles and an already bootstrapped
environment. The panel never bootstraps AWS or grants permissions to itself.

Settings are stored in ignored, owner-only `.cloud-control/config.json`. Account/profile alone permit
status inspection. For deployment, expand the JSON settings and fill the public fields shown in
[config.example.json](../tools/cloud_control/config.example.json), replacing every placeholder:
grouped Apple IDs, numeric prod appAppleId, approved product IDs, complete same-account secret ARNs,
reviewed Apple DER root directory/fingerprints, and absolute path to the reviewed product policy.
Optional alignment needs the immutable worker image and `alignment_benchmark_file` with real reviewed
measurements. [Paid-cloud launch gates](PAID_CLOUD_OPERATIONS.md) still apply; the panel does not
approve budgets/benefits or automatically turn admissions on. Unknown/credential fields are rejected.
Configure account-level budget notifications separately before enabling paid work; the Stockholm
regional templates omit the unsupported `AWS::Budgets::Budget` resource. No budget is provisioned by the panel.

## Release tags

The separate `Tag verified main` workflow runs after full `CI` success for a **push to this repository's
main**, including backend contracts, all iOS unit tests and device Release compilation. UI tests run
only on PRs into main that change iOS inputs (app/resources/project/dependencies/UI scenarios),
not documentation/backend-only PRs, and are not repeated for the post-merge tag. PR/fork/failed/cancelled/reusable publishing runs cannot tag.
The annotated immutable name is `backend-<CI run number>-<12-char SHA>`. It records the exact tested
main commit even when another merge arrives. Re-running accepts the identical tag and refuses to move
one. Main push CI is grouped per event/commit and survives newer merges; only superseded PR checks
are automatically cancelled. No deployment follows tagging. The first tag appears after this change merges and main CI passes.

**Получить теги** fetches main/release tags without forcing existing tag changes. Prepare and deploy
each recheck annotation, SHA suffix, ancestry in current origin/main and successful matching push-CI
head/run number via GitHub. A local branch, PR success or unverified tag cannot select production code.
Older revisions without these verified tags are not selectable.
The iOS checks use a shared test build, an exhaustive unit shard and eight UI shards only on iOS-changing PRs into main; see [IOS_CI.md](IOS_CI.md).
Tag latency depends on complete CI and runner availability, not a fixed ten-minute timer.

## Prepare, deploy, roll back

1. Select a tag in **Версии и деплой** and choose **Подготовить план**. The panel checks AWS identity
   and stack state, exports that exact tagged source, builds the hash-locked Linux asset, installs
   locked npm dependencies without install scripts, and synthesizes a prod assembly with explicit
   account/region and lookups disabled. Policy, roots and optional benchmark files are copied into it.
   Preparation does not mutate AWS. The live stacks/templates/tags form its baseline.
2. Read **Изменения**, including the CDK diff and IAM/deletion/replacement effects. Unexpected stacks,
   environment or unauthenticated application routes block the plan. Oversized diffs that cannot be
   reviewed in the panel also block it. Already-deployed components cannot be silently omitted by
   changing cloudComponents/paidAlignment; removing a stack requires a separate manual migration.
3. Choose **Развернуть**, confirming `<account ID>/<tag>`. A plan is single-use and expires after one
   hour. Configuration/file changes, changed live AWS baseline, moved/unapproved tag or busy/failed
   stack require fresh preparation. CDK deploys the **prepared assembly**, not the working checkout,
   with normal CloudFormation failure rollback and ControlReleaseTag/ControlRevision/ControlOperation
   stack tags. After deployment only non-inference smoke tests run. Failed/incomplete checks produce
   a warning, not a healthy verdict or automatic rollback.

For rollback, prepare an **older verified tag** and follow the same flow. It deploys old code using
current reviewed environment configuration; it does not restore databases, reverse purchases, reset
quota or guarantee schema compatibility. CloudFormation failure rollback is a separate mechanism.
Follow the runbook for coordinated cross-table recovery. Never use a code rollback as a data restore.

Multi-stack deployment is not atomic: later stack failure can leave mixed revisions, displayed per
stack in the overview. The panel never destroys stacks, restores data or automatically retries failed
deployments. One operation/server per state directory is enforced; after a hard stop unfinished work
is marked interrupted, not retried. A surviving child process blocks another operation until it exits.
Normal shutdown waits for the operation. Inspect actual AWS state after interruption. This is not a
distributed lock: coordinate other computers/pipelines. CloudFormation/baseline checks detect observed
conflicts but cannot prevent every external change between preflight and execution.

## Real production API suites

The target comes from the foundation CloudFormation output; arbitrary URLs are not accepted. Probes
use normal TLS verification on the regional HTTPS API Gateway hostname, refuse redirects and bound
timeouts/response sizes. CI does not run these against production.

| Suite | Checks | Spend / coverage |
|---|---|---|
| Smoke without token | Account/entitlement/request/translation routes reject unauthenticated calls; unknown route is 404; enabled paid alignment rejects unauthenticated calls | No model calls. Authenticated coverage explicitly skipped; overall warning |
| Smoke with token | Adds profile binding, entitlement/allowance/catalogue schema, nonexistent key isolation and malformed admission rejection | No valid inference; does not prove provider or real cross-account isolation |
| Explicit inference | Passing preflight; one context + one word request; durable result, schema and same-key replay | Two new operations plus idempotent repetitions. Confirmation `2`; spends test quota/provider budget |

Use an existing **dedicated prod test subscriber** and a fresh Cognito access token from normal app
login. Save only that token in a local file (`chmod 600 /absolute/path/to/access-token.txt`) and set
access_token_file. It is read at test time, never returned to the UI or included in reports. No refresh
token, AWS key, password or token value is accepted as a form field. Expired/foreign/revoked tokens
fail tests. The panel neither creates a subscriber nor purchases a subscription automatically.

Inference UUIDs are persisted **before POST**. Lost POST responses recover through GET by key, without
a second submission. Only a known success is replayed to check idempotency. First inference failure
stops the suite before the second feature; pending/unknown keys remain in the report. Restart never
resubmits work. Each newly confirmed inference run is a separate paid intent. Payment/refund/deletion,
real media uploads and alignment quality remain separate acceptance procedures.

## Validation and operator data

```sh
python -m unittest tools.cloud_control.test_control -v
node --check tools/cloud_control/web/app.js
bash -n scripts/cloud-control.sh scripts/tag-verified-main.sh
```

Tests use fake AWS/HTTPS/GitHub, a disposable local Git origin and temporary HTTP server; no AWS
deployment/paid calls. Backend CI includes them. Browser QA uses the real local UI. Live deployment/API
acceptance remains unexecuted until an authorized AWS account and test credentials are configured.

Plans include source/dependencies/assets and consume disk. Keep `.cloud-control/` private; history
contains infrastructure identifiers and test request keys. Output is bounded and JWT/AWS access-key
patterns are redacted; raw AWS exceptions and secret values are not exposed. Remove old plan folders
only with no active operation, preserving needed audit records. Never edit an approved plan; prepare anew.

The HTTP server enforces exact loopback Host/Origin, per-start CSRF, same-origin resources, no CORS,
no-store responses and CSP. Other processes with the local user's filesystem access are outside this
boundary. No remote dashboard service or new public AWS management endpoint is created.

References: [CDK assembly deployment](https://docs.aws.amazon.com/cdk/v2/guide/cli.html),
[CDK deploy/rollback](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-deploy.html),
[GitHub workflow events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows),
[AWS CLI SSO setup](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html).
