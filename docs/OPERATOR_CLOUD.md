# First-stage private backend: prepare and publish

This is the implemented operator assembly. It does not require Apple IDs, App Store products,
certificates, subscription policy or an OpenAI key. Regional resources are fixed to eu-north-1.
The existing subscription assembly remains the second-stage option.

## What is included

- `ForeignLanguageLearnerOperator-prod`: Cognito password/SRP client, protected HTTP API, direct
  Bedrock Qwen3 235B Instruct requests, a DynamoDB request/idempotency table, logs and alarms/SNS.
- `ForeignLanguageLearnerOperatorAlignment-prod`: the same protected API's alignment routes,
  private versioned S3 storage, job/admission table, immutable worker image, Fargate/Step Functions,
  finalizer/reconciliation and monitoring. This is included by default, with real image/measurement
  prerequisites. Explicitly deferring audio creates only the first stack; it is not full-stage acceptance.

Self-registration and OAuth redirects/implicit flow are disabled. You create the named operator in
Cognito manually. Access-token JWT issuer, client, scope and token type are checked; `GetUser`
verifies the live session, username and subject. First valid login permanently pins the subject in
the operator table. Other pool users and recreated usernames cannot adopt that authority/data.
Changing the operator requires an explicit migration of this binding, never deleting it to bypass
ownership checks. Runtime roles have resource-scoped access and do not receive AWS admin access.

The model path has no SQS: it runs one Converse call with SDK retries disabled, bounded output and
an 18-second network read timeout inside a 28-second Lambda/30-second HTTP integration. AWS JSON
grammar compilation can take about 90 seconds on first use, so this path asks for JSON and applies
the existing strict server validator instead of enabling that incompatible cold compilation path.
Malformed output fails the operation; no second paid repair call is made. Paid work has a configurable
daily admission cap (default 50, max 1000) and Lambda concurrency 2. API throttling applies to all routes.

Requests require a canonical UUID `Idempotency-Key`. A DynamoDB transaction records the key and
daily admission before model submission. POST returns 200 for known success or 202 with state for
unfinished/failed/unknown work. GET `/v1/requests/{id}` and `/v1/requests/by-key/{key}` recover it.
Repeated identical requests reuse that record; different payloads conflict. A running request older
than 30 seconds is reported as `outcome_unknown`, never re-executed. Result/idempotency lifetime is
24 hours, enforced by the API as well as asynchronous TTL; do not reuse keys after that horizon.
No source excerpt is stored. Results are temporary and excluded from table backups. Request IDs,
latency, token counts and error categories are logged, not text/results/passwords/tokens.

The source language contract remains en/fr/es/de/it/pl → Russian; choosing a model that supports
Russian → Polish does not itself add that direction to the application contract. This is a backend
release; the existing iOS Apple login UI is not a password login client. Use the local login helper
and API checks for initial backend acceptance; a native password UI can be integrated separately.

## Before preparation

1. Merge the implementation PR and wait for successful main CI and its automatic annotated
   `v<backend/VERSION>-backend.<CI run number>` tag (for example `v0.0.1-backend.123`). Older tags such as `backend-199-df7dc61bfc31` do not contain this assembly;
   the dashboard explains/filter them in operator mode. Do not manually create a release tag.
2. Confirm the project Region in AWS Settings → View all projects → Overview → Additional Info.
   The configured SDK Region is Stockholm. Check spend status in AWS Settings → Billing.
3. Prepare CDK infrastructure once if the readiness check reports no `CDKToolkit`. This creates
   deployment roles and asset stores, so inspect its template/IAM permissions before running it:

   ```sh
   cd infra/alignment
   npm ci --ignore-scripts
   AWS_PROFILE=fll-control node_modules/.bin/cdk bootstrap aws://YOUR_PROJECT_ID/eu-north-1
   ```

   The panel does not bootstrap or grant itself permissions. No bootstrap/deployment is performed
   by opening it or checking readiness. Prepare/deploy still use the explicit named SDK profile.
4. For audio, obtain an immutable ECR worker digest and matching actual measurements. Build from
   the chosen verified source revision using the existing Dockerfile and helper:

   ```sh
   python scripts/alignment-image.py \
     --base-image python@sha256:REVIEWED_BASE_DIGEST \
     --ffmpeg-version REVIEWED_DEBIAN_VERSION \
     --model-sha256 REVIEWED_WHISPER_BASE_SHA256 \
     --model-url https://openaipublic.azureedge.net/main/whisper/models/REVIEWED_WHISPER_BASE_SHA256/base.pt \
     --output /absolute/path/to/new-image-provenance.json
   ```

   Supply real immutable values. The command builds Linux/amd64 locally; it does not publish by
   default. `--publish --create-repository` explicitly creates a private immutable-tag ECR repository
   if absent and uploads the image, using temporary Docker authentication. This incurs AWS image
   storage usage. The helper does not create runtime/service roles or deploy the API. Docker context
   excludes local state/credentials; never add them to the build context.

   The provenance file is not a benchmark/quality acceptance report. Record runtime, peak memory,
   cost and manually reviewed six-language quality using [the benchmark procedure](ALIGNMENT_BENCHMARKS.md).
   The report must contain `workerImageDigest`, positive `maxJobCostUsd` and `languages` with en/fr/es/
   de/it/pl rows: `qualityAccepted: true`, `runtimeSeconds` ≤13500, `peakMemoryMiB` ≤8192 and nonnegative
   `costUsd` ≤maxJobCostUsd. Do not substitute synthetic CDK test reports for measured results.
5. Bedrock metadata access for Qwen is authorized, but the first actual inference was rejected
   while AWS verifies the project. Metadata readiness cannot prove inference access or language
   quality; finish the bounded live acceptance after verification clears. Do not change Regions.

## Publish from the dashboard

1. Start `bash scripts/cloud-control.sh` and open http://127.0.0.1:8767.
2. In **Настройка**, select **Первый этап**. Enter the project ID/profile, operator username (default
   `operator`) and daily model limit. Keep audio enabled and provide ECR repository, sha256 digest
   and absolute benchmark path. Apple settings are hidden and ignored for this assembly.
3. Save, then **Версии и деплой → Проверить готовность**. It reads AWS identity, CDKToolkit, Bedrock
   access metadata, image existence and benchmark validity; it does not invoke models, publish images
   or provision infrastructure. Missing artifacts are explicit failures, not dummy defaults.
4. **Получить теги**, select a compatible verified release and **Подготовить план**. The panel archives
   that exact source, builds hash-locked Linux dependencies without Apple roots, synthesizes both
   stacks, verifies the expected account/region and JWT routes, and runs a non-mutating diff.
5. Review IAM/resource changes and **Развернуть** with the existing project/tag confirmation. Plans
   expire after one hour and cannot be reused/edited. Configuration, source artifacts or AWS baseline
   changes require a fresh plan. This does not create your user or subscribe an email to SNS.

Existing installed stacks cannot be silently excluded by changing modes/audio options. Moving from
this stage to the subscription stage requires a reviewed migration, not a mode toggle and deletion.

## Create and exercise the operator

After deployment, the overview displays API URL, Cognito pool/client IDs, expected username, model
and SNS topic. In Cognito → the displayed User Pool → Users → Create user, create that exact username
manually. Use a strong password matching the deployed policy (14 characters, upper/lower/digit/symbol).
If a temporary password is used, complete the initial password challenge during first login.

The local helper prompts without echoing passwords and saves only a short-lived access token to a
new mode-600 file. It does not store the password, ID token or refresh token:

```sh
.cloud-control/venv/bin/python scripts/operator-login.py \
  --client-id CLIENT_ID_FROM_OUTPUT --username operator \
  --output /absolute/private/path/new-access-token.txt
```

Set that file in dashboard **Настройка → Файл access token для проверки API**. Re-run the helper with
a new output filename when it expires. Basic checks cover protected routes/profile, invalid input
and unknown-key access without model spend. The explicit inference suite performs at most two new
paid model calls, validates the existing JSON contracts and same-key replay, and persists keys before
POST. An interrupted run never automatically resubmits. Audio acceptance separately exercises real
upload/start/result/cancel/expiry; merely checking JWT rejection is not audio quality validation.

Subscribe the operator's chosen destination to the output SNS topic and confirm the subscription.
Exercise an alarm and verify delivery. Logs retain one week. Retained Cognito/table/bucket resources
and image storage persist until explicitly cleaned up; keep them while using the service and decide
on cleanup when retiring it. Deployment is not an automatic cleanup or restoration procedure.

## Local verification

```sh
PYTHON=.cloud-control/venv/bin/python bash scripts/test-cloud-contracts.sh
.cloud-control/venv/bin/python -m unittest tools.cloud_control.test_control -v
cd infra/alignment && npm ci --ignore-scripts && npm test
```

Tests use fake/local AWS, including actual local DynamoDB for transaction concurrency; no cloud
resources or paid inference are created. The infrastructure assertions include all operator and
audio routes, no Apple/SQS dependency, regional scoped Bedrock permission and benchmark rejection.
