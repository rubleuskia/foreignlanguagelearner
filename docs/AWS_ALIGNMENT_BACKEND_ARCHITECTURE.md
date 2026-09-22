# AWS backend for audio + TXT alignment

**Status:** Reviewed implementation proposal; not shipped or authorization to deploy.  
**Reviewed:** 2026-09-22 against `align.py`, `guided.py`, the iOS importer, and AWS documentation.  
**Priority:** minimum total cost, no idle processing workers, no reuse of user media.

## 1. Review decisions and corrections

Use **API Gateway HTTP API → lightweight Lambda → DynamoDB + Step Functions Standard → one ECS Fargate task**, with S3 temporary storage, ECR images and CloudWatch. Use presigned uploads. Lambda never runs FFmpeg, PyTorch or alignment. The small control plane is justified by job-access checks, multipart management, idempotency and cancellation; avoiding Lambda was adding complexity rather than demonstrably reducing total cost.

| Original decision or claim | Reviewed decision and reason |
|---|---|
| HTTP API directly implements start and status | Use Lambda for every product endpoint. HTTP API's listed Step Functions integrations include start/stop, but not `DescribeExecution`. The previously linked tutorial did not establish the whole HTTP API contract. |
| Identity Pool provides job-scoped ownership | Authentication and S3 authorization are distinct. User chose public testing without sign-in. Use a per-job bearer capability, private S3 and global admission limits; defer accounts. An Identity Pool alone would not create trustworthy job ownership records. |
| Execution state is enough; database only needed for progress | Store job capabilities, upload sessions, immutable input versions, start intent, publication state and expiry in DynamoDB on-demand. A job exists before its execution. |
| Stopping execution runs its cleanup branch | False. Stop is not a `finally` block. Use a separate reconciler for aborted/crashed workflows and orphaned tasks. |
| A shared ECS task role is automatically restricted to each job | False. Environment variables and S3 key conventions do not scope IAM credentials. See the explicit trust boundary below. |
| S3 lifecycle deletes at the promised TTL | Expiration is asynchronous. API access expiry and physical deletion are different guarantees. |
| Exit 0 means publish subtitles | Require validated result manifest and a conditional job-state publication. Exit 0 alone is insufficient. |
| Only zero-duration words require review | Existing `align.py` also flags repaired engine duplicates. Preserve both triggers. |
| Benchmark last | Benchmark the unchanged local pipeline in the container first, before committing production size, model or timeout limits. |

AWS references: [HTTP API integration subtypes](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-aws-services-reference.html), [ECS integration](https://docs.aws.amazon.com/step-functions/latest/dg/connect-ecs.html), [best-effort cancellation](https://docs.aws.amazon.com/step-functions/latest/dg/connect-to-resource.html), [ECS task roles](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html), [S3 expiration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-expire-general-considerations.html).

## 2. Product scope and unresolved release choices

Implement one matching audio + UTF-8 TXT pair per job. Return cue-timed SRT/VTT for local import. Do not implement cloud library/sync, multi-track alignment, automatic transcription as replacement text, GPU, arbitrary model selection, or word highlighting in this project.

The existing app has no accounts or backend. Cloud alignment must be an explicit optional flow; normal local import remains available without an account or network. Show upload destination and retention before submitting files. **User confirmed: public testing without sign-in, maximum recording duration 60 minutes.** Public means anyone can create a test job; it does not mean public access to other testers’ files.

The following specifies the public test release. Authentication and broader production hardening are deferred to the general [future improvements backlog](FUTURE_IMPROVEMENTS.md). Resource/profile values remain development choices subject to measurement:

- No Cognito, account creation, sign-in or shared application secret. The client generates a fresh 32-byte cryptographically random job access token per create operation, encoded as base64url without padding. Store it in Keychain. The server stores only SHA-256 of the token. All subsequent requests require that capability; it is authorization for one job, not verified user identity.
- Region `eu-central-1`; CPU-only Linux/x86_64 Fargate. Initial benchmark candidate: 2 vCPU, 8 GiB, 20 GiB ephemeral storage, `base/guided`.
- Development admission limits: audio at most 1,000,000,000 bytes and 3,600 seconds; TXT at most 10,000,000 bytes; generated SRT and VTT each strictly less than 10,000,000 bytes. These are separate limits.
- Two active processing jobs globally, at most 10 accepted starts per UTC day. At most 20 new jobs per UTC day and 20 outstanding upload sessions globally. Use atomic DynamoDB counters, not approximate scans. Return 429 with Retry-After (60 seconds for concurrent capacity, seconds until UTC reset for daily caps). There is no inference queue. Tokens/IP addresses are not trustworthy per-person quotas; do not describe them as such.
- Upload session lasts 24 hours; individual signed URLs last 15 minutes. Results/diagnostics are accessible for 24 hours after terminal completion. Normal input cleanup starts at terminal completion. Orphan-object lifecycle fallback: 3 days; physical deletion may occur later.
- Development execution timeout: 4 hours; worker wall-clock watchdog: 3 hours 45 minutes. Release only after benchmarking demonstrates the selected input limit fits both time and memory with headroom.
- No automatic inference retries. Users retry a failed job by creating a new job and uploading again. Transport/control retries do not create new compute attempts.

The 3,600-second limit is user-confirmed. Do not increase it to accommodate a long audiobook; use separately prepared matching excerpts. Benchmark the chosen profile at this limit and lower admission/resource limits if measurements demand it. Future production limits require an explicit decision.

## 3. Preserve the actual alignment contract

Read `tools/subtitle-aligner/align.py`, `guided.py`, `test_align.py` and `README.md` before coding. Keep CLI flags/defaults and existing tests working. The CLI default is `small`; the backend profile is a separate configuration, not a change to that default.

1. Decode TXT as UTF-8 with optional BOM; preserve existing NFC/whitespace normalization.
2. Keep Stable-ts at `2.19.1` initially. Lock Python, CPU PyTorch, transitive packages, FFmpeg, image digest and model checksum in a reproducible worker build.
3. Preserve direct/guided alignment behavior, duplicate repair, word-text equality and timing validation. Guided mode uses rough transcription for anchors; output wording comes from TXT.
4. Guided code transcribes the complete audio and loads the complete 16 kHz waveform; its approximately 60-second chunks do **not** bound total memory. Sparse anchors can cause failure when a planned interval exceeds 180 seconds. Do not advertise arbitrary audiobook length.
5. Strict cloud mode rejects untimed words. An explicit `allow_untimed_words: true` request may retain them, using existing cue behavior. Never silently switch to review mode after a strict failure.
6. Preserve cue targets: 42 characters per line, two-line target, 6-second target, split on pauses over 0.8 seconds and sentence punctuation. These are grouping targets, not proof every indivisible word/cue satisfies a hard limit.
7. Cloud MVP fixes offset to zero and always generates both formats. Reject nonzero offsets and arbitrary output/model/CLI arguments. A single uploaded recording has no external timeline to offset into.
8. Existing JSON has `requires_review` when untimed words **or** `engine_duplicate_words` exist. Use that field, not inferred status from exit code.
9. Add a cloud boundary check after rendering: every cue has finite `0 <= start < end`, nondecreasing/nonoverlapping cue intervals, and end no greater than probed duration + 0.100 seconds. Permit start at zero. Do not clamp or silently trim out-of-range cues; reject with `TIMING_OUT_OF_RANGE`.
10. Preserve markup escaping, normalized TXT and schema-1 alignment JSON. Word times are seconds relative to input; JSON cue times are integer milliseconds. Do not mix units.
11. Capture stdout/stderr privately in ephemeral storage. Existing exceptions/diagnostics can include words and paths; do not stream them to ordinary CloudWatch logs. Emit only whitelisted job ID, stage, elapsed time, counts and stable error codes.

Diagnostics exist only for some current CLI failure paths. Worker code must tolerate a failure with no diagnostic JSON. Raw diagnostics may include the full text/rough transcription: treat them as private user artifacts, never telemetry.

## 4. Job record and state machine

Use an opaque server-generated UUID as `job_id`; execution ARN is internal. Creation accepts the client-generated capability in `Authorization: Bearer <token>`. Validate that it decodes to exactly 32 bytes; store its SHA-256 as `access_token_hash`. Every job endpoint compares the presented token hash in constant time. Missing/malformed bearer returns 401; unknown job or mismatching capability returns 404. A job ID alone grants no access. Never accept an owner ID from JSON or put tokens in URLs/logs. A lost token cannot be recovered by an account in this test release; explain this in the UI.

DynamoDB record fields (write an explicit schema and serializer):

```text
job_id, access_token_hash, schema_version=1
created_at, updated_at, upload_expires_at, result_expires_at?, delete_after
status, revision, error_code?
profile_id, language, allow_untimed_words
expected_audio_bytes, expected_text_bytes, expected_audio_sha256, expected_text_sha256
multipart_upload_id?, completed_parts[]
audio_key, audio_version_id?, text_key, text_version_id?
execution_name, state_machine_version_arn, canonical_execution_input?, execution_arn?
start_requested_at?, task_arn?, worker_claimed_at?
manifest_key?, manifest_version_id?, requires_review?
cancel_requested_at?, cleanup_pending, admission_released, upload_slot_released
admission_day?, result_stage?, worker_outcome_key?
```

Use integer epoch seconds for storage deadlines and UTC ISO-8601 strings in API responses. `delete_after` is DynamoDB garbage collection (7 days after completion or upload expiry), not an authorization check. Do not delete records needed to reconcile an active task. [DynamoDB TTL](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html).

Allowed state transitions:

```text
awaiting_upload -> starting -> running -> succeeded | succeeded_with_review | failed
awaiting_upload -> expired
awaiting_upload | starting | running -> cancelling -> cancelled
starting | running -> failed (including timeout)
```

Upload progress is client-local. `starting` means durable start intent; it is not a guaranteed queue position. Successful records remain successful after result expiry; expose `result_available: false` and return 410 for downloads. Do not overwrite completed history with `expired`.

Only the control plane/reconciler writes product state. Worker may conditionally claim its job and record its task ARN/stage, but cannot publish success. Implement all state changes using conditional writes with expected state/revision. Terminal states cannot turn into success later. A cancel that wins the conditional transition suppresses publication; a success that wins first makes cancel return the existing terminal state.

### Start and crash recovery

1. Verify capability, deadlines, uploaded sizes and pinned S3 versions. Persist immutable parameters before dispatch.
2. In one DynamoDB transaction, change `awaiting_upload` to `starting`, save canonical execution JSON/version/name, acquire a global admission slot and increment the UTC-day start counter. A duplicate start reuses this record and consumes neither a slot nor a daily start twice. Daily admitted-start counters are not decremented on failure; the active slot is released at termination.
3. Use execution name `alignment-<job UUID>` and the identical persisted input bytes for every `StartExecution` retry. Never generate a new name to get around `ExecutionAlreadyExists`.
4. Persist returned ARN. If the caller times out or Lambda crashes, a scheduled reconciler replays the persisted start intent. Handle `ExecutionAlreadyExists` by describing the known execution and reconciling it, including after completion. [StartExecution idempotency](https://docs.aws.amazon.com/step-functions/latest/apireference/API_StartExecution.html).
5. State machine uses `ecs:runTask.sync` once, then a finalizer Lambda to inspect exit/task result and private manifest. Catch failure into the same finalizer. No `Retry` on the compute state, no console redrive in MVP.
6. Worker conditionally claims `starting` before downloading; a second task that cannot claim exits without running inference. This protects computation even if dispatch is repeated unexpectedly.
7. Finalizer atomically changes eligible active state to terminal and releases admission counters exactly once (`admission_released` guard). Cleanup failure must not erase an already published result.
8. A 5-minute EventBridge-triggered reconciler repairs pending dispatches, missing terminal updates, overdue jobs, cancellations and cleanup failures. Tag ECS tasks with the server job ID and dedicated backend identifier at launch. When task ARN persistence was interrupted, discover tasks only in this dedicated cluster/backend scope, confirm tags/job record, then stop overdue or cancelling tasks; do not assume a missing ARN means no task exists. Scan is acceptable only for this explicitly small MVP; paginate, bound batch size, alarm on backlog. Query/partition redesign is required before larger scale.

## 5. Upload and API contract

API JSON errors use `{ "error": { "code": "...", "message": "..." }, "job_id": "..." }`; omit job ID before creation. Reject unknown fields. Return 400 invalid parameter, 401 missing/malformed capability, 404 unknown job or wrong capability, 409 invalid state/conflict, 410 expired resource, 413 declared input too large, 429 admission/rate limit. Retry 429/5xx with bounded backoff; validation/capability errors are not automatic retries.

### Create

`POST /v1/alignments`, headers `Idempotency-Key: <client UUID>` and `Authorization: Bearer <new random job token>`, JSON:

```json
{
  "language": "pl",
  "profile_id": "base-guided-v1",
  "allow_untimed_words": false,
  "audio": {"extension": "mp3", "size_bytes": 104857600, "sha256": "<64 lowercase hex characters>"},
  "text": {"size_bytes": 245678, "sha256": "<64 lowercase hex characters>"}
}
```

Development allowlist: `pl`, profile `base-guided-v1`, audio `mp3`, `m4a`, `wav`. Reject zero sizes, malformed checksums, unsupported formats and unapproved profiles. Do not forward original filenames as paths. Reject reuse of an existing job token for a different Idempotency-Key; this keeps each capability scoped to one job. Create-key uniqueness is scoped to the token hash; persist request hash and response job ID transactionally for 7 days. The client must persist token and idempotency key before dispatch; a retry uses both original values. Count a new job against global daily/upload quotas in this same transaction. Repeating identical content returns the same job, differing content with same key returns 409. If that job expired, return its existing status; client must use a new key.

Response 201 (200 on replay): job ID, status, deadlines, fixed upload part size, part count and TXT signed PUT URL with **all required headers**. Do not return signed URLs in persistent job records or logs.

### Multipart audio (one protocol for all supported audio sizes)

- Backend creates S3 multipart upload at `jobs/<job_id>/input/audio.<approved extension>`. Part size 16 MiB; last part may be smaller. Backend stores upload ID. Client does not choose keys or upload IDs.
- `POST /v1/alignments/{id}/upload-urls` with `part_numbers: [1,2,...]` (at most 20 per request) returns corresponding UploadPart URLs/headers, plus renewed TXT URL when `include_text: true`. Reject part numbers outside declared size. Only allowed in `awaiting_upload` before deadline.
- iOS writes each part to a local file and uses a file-backed background URLSession upload. Save successful part number/ETag and client-side bytes/checksum state. ETag is not a SHA-256 checksum.
- `POST /v1/alignments/{id}/complete-upload` receives sorted `{part_number, etag}` pairs. Server verifies with `ListParts`, expected sizes/count and stored upload ID, then completes audio. Retry an ambiguous completion by inspecting the generated key/version rather than creating a second upload.
- TXT uses a signed single PUT with checksum header. Enable S3 versioning and pin the selected audio/TXT version IDs at completion. Reusing an unexpired PUT URL can replace a current object; the worker must always read the pinned versions. Never read an unversioned latest key after start.
- At completion, verify sizes with `HeadObject`, persist version IDs and mark upload metadata complete. Worker computes both full-file SHA-256 values and compares to the immutable declared values before inference. Multipart checksums must not be assumed equivalent to plain full-file SHA-256.
- Add `GET /v1/alignments/{id}/upload` to retrieve completed server parts and completion state for relaunch recovery. Enforce the global outstanding-upload/session and daily-create caps from section 2; these are separate from compute admission. Release an upload-session slot once at start, cancellation or upload expiry.

See [multipart upload lifecycle](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html) and [presigned PUT replacement behavior](https://docs.aws.amazon.com/AmazonS3/latest/userguide/PresignedUrlUploadObject.html). API checks do not by themselves enforce S3 byte limits; sign supported length/checksum headers, verify actual parts/objects, abort invalid uploads, and rate-limit URL issuance.

### Start, status, results, cancel

- `POST /v1/alignments/{id}/start` has empty JSON. Returns 202 with current state; replays never create another execution. Requires completed input metadata. Parameters were fixed at create time.
- `GET /v1/alignments/{id}` returns job ID, status, optional stage, error code, timestamps, `requires_review`, `result_available` and expiry. Stage is coarse (`downloading`, `aligning`, `validating`, `uploading`); percentage is null. Poll every 15 seconds in foreground with jitter, back off to 60 seconds on transient failure; stop at terminal state/background.
- `GET /v1/alignments/{id}/result` returns 409 before success, 410 after result expiry. For success return signed SRT/VTT/JSON URLs, URL expiry, per-file byte count and SHA-256, counts and `requires_review`. URL lifetime is min(15 minutes, remaining result-access lifetime). URLs always pin artifact versions.
- `GET /v1/alignments/{id}/diagnostics` is an explicit capability-authorized action for failed/review jobs, subject to the same expiry. Return only present artifact names/signed URLs. No administrative export UI or automatic diagnostic upload beyond private S3 storage.
- `POST /v1/alignments/{id}/cancel` has empty JSON, conditionally sets `cancelling`, invokes `StopExecution` when it exists and `StopTask` when known. Return 202 until execution/task termination is confirmed, then `cancelled`. Replays are safe. Cancelling a completed job returns its existing terminal status.

## 6. Worker, publication and cleanup

Keep the CLI executable and import behavior stable. Add a thin worker adapter under `tools/subtitle-aligner/worker/`; do not require a broad package rewrite before testing. Invoke the existing core through explicit typed options; no shell-built command string and no user-controlled checkpoint paths.

Worker steps:

1. Claim job, record task ARN, validate versioned input specification and immutable profile.
2. Download pinned versions to a fresh ephemeral job directory. Use fixed local filenames, including `.txt` suffix required by CLI. Verify bytes/hash before decoding.
3. Probe audio with ffprobe and enforce finite positive duration, allowed stream/codec profile, input bytes and wall-clock budget. Audio files with embedded cover artwork remain audio; reject actual video content for this flow. Bound subprocess runtime/output.
4. Run preserved alignment. Use prepackaged weights; fail on missing weights instead of accessing a model hub at runtime.
5. Validate cues, output byte limits and report. Upload private artifacts under `jobs/<id>/attempt/1/`; upload `manifest.json` **last** with schema version, job ID, input versions/hashes, image/profile digest, output keys/versions/hashes/sizes, review flag/counts. Exit 0 only after all uploads complete.
6. Finalizer validates manifest identity, expected artifact set, versions and sizes and exit result before conditionally publishing its pointer in DynamoDB. Only the result endpoint grants reads for a published, successful job. Partial artifact upload never becomes success.
7. On deterministic error, upload a small private `outcome.json` containing job ID, attempt=1 and whitelisted error code, optionally upload existing diagnostics, and exit nonzero. Finalizer treats a missing/corrupt outcome as `INFRASTRUCTURE_FAILURE` (or the observed timeout/OOM category), not success. `SIGTERM` cancels child processes and never publishes a manifest; correctness must also survive SIGKILL/OOM without running handlers.

Stable errors: `INVALID_TEXT`, `INVALID_AUDIO`, `INPUT_TOO_LARGE`, `DURATION_LIMIT`, `CHECKSUM_MISMATCH`, `TEXT_MISMATCH`, `INSUFFICIENT_ANCHORS`, `INVALID_TIMINGS`, `TIMING_OUT_OF_RANGE`, `OUTPUT_TOO_LARGE`, `WORKER_RESOURCE_LIMIT`, `WORKER_TIMEOUT`, `INFRASTRUCTURE_FAILURE`. Unclassified failures map to the last code, with private details preserved where possible.

Do not copy inference errors into Step Functions cause/output: workflow histories also persist. Use only IDs, counters and safe codes in workflow data/logs. Suppress raw ECS/container output in user error responses.

Cleanup is idempotent and external to worker correctness:

- Normal terminal completion: abort unfinished multipart uploads and delete **all versions** under the input prefix; preserve published output/diagnostics until result expiry.
- Cancel/failure: stop compute first, then remove input and partial artifacts; preserve diagnostic artifacts only until terminal + 24 hours.
- Reconciler performs deadline deletion and retries failed cleanup. URLs already issued cannot be revoked merely by changing database status; deleting addressed S3 versions removes their object access.
- S3 lifecycle fallback covers current versions, noncurrent versions, expired delete markers and incomplete multipart uploads. Enabling versioning without noncurrent-version deletion does not meet the retention requirement.
- Never claim a guaranteed deletion deadline from S3/DynamoDB TTL. Alarm if application cleanup is still pending 1 hour after its due time.

## 7. IAM, networking and cost boundary

Private S3 bucket, Block Public Access, bucket-owner-enforced ownership, TLS-only policy, SSE-S3. No public downloads. Capability checks apply to every job endpoint including upload renewal and cancellation. Creation is deliberately public and does not authenticate a person. Limit API Lambda roles to needed bucket/table/workflow operations. Separate ECS execution role (image/log access) from application task role.

**MVP worker trust boundary:** one shared task role can read/write the backend's temporary job bucket and conditionally claim job records. This is a trusted service boundary, **not per-job IAM isolation**. Its policy cannot claim isolation by interpolating `JOB_ID`. Do not expose these credentials to iOS, user scripts or plugins. If hard tenant isolation becomes required, redesign with job-scoped brokered credentials/URLs before enabling that requirement; do not create/delete IAM roles per upload as an improvised solution.

Use a dedicated VPC with public subnet, public IPv4 assigned to Fargate, no inbound security-group rules, outbound HTTPS and required DNS; no listener in worker. This avoids a permanently charged NAT Gateway. Restrict S3 access via a gateway endpoint policy where configured. Do not silently replace this with paid interface endpoints or NAT. Public IPv4, ECR storage/pulls, logs and scheduled Lambda calls still cost money when inference is idle.

Provision infrastructure once, not per job. Use **AWS CDK in TypeScript** under `infra/alignment/` and Python Lambda handlers under `backend/alignment/`. Pin dependencies, use immutable image digests and state-machine versions, and include budgets/alarms. No credentials or AWS account IDs hardcoded in committed source.

Do not retain the previous US-region illustrative dollar totals as Frankfurt pricing. Before release, record target-region rates and measured task runtime in `docs/ALIGNMENT_BENCHMARKS.md`:

```text
job compute = billed task hours * (vCPUs * regional CPU rate + GiB * regional RAM rate)
            + extra ephemeral storage (if any) + public IPv4 time
monthly total additionally includes ECR, S3 requests/storage/versions/transfer,
API Gateway, Lambda, DynamoDB, Step Functions, logs and alarms
```

Measure cold image startup as part of billed task lifetime. Compare `base/direct`, `base/guided`, `small/guided` on 5-minute, 30-minute and maximum-length matching fixtures. Record peak RSS/disk, wall time, reviewed timing quality and failure behavior. A compressed file's byte size is not a runtime estimate. Consult [Fargate pricing](https://aws.amazon.com/fargate/pricing/) when collecting the actual regional rates; no price quote is asserted here.

## 8. iOS integration and implementation order

1. **Container + benchmark first:** preserve `python3 -m unittest discover -s tools/subtitle-aligner -p 'test_*.py'`; add worker tests with fake engine/S3 and run real representative audio separately. Do not deploy while profile/limits lack measurements.
2. **Backend domain logic:** job schema, conditional transitions, capability authorization, global admission counters, manifest validation and OpenAPI contract. Tests must simulate duplicate requests, races and crashes, not just happy paths.
3. **Infrastructure + reconciliation:** deploy to an explicitly selected development account only when deployment is requested. Verify successful task, nonzero exit, missing manifest, OOM, timeout, aborted workflow, missing task ARN, late worker and failed cleanup. Assert counters release once and no second inference starts.
4. **Direct uploads/API:** implement the specified multipart protocol, stale URL version-pinning test, cross-job capability tests, expired access, interrupted completion and start response loss. Verify physical deletion includes all versions and incomplete uploads.
5. **iOS services:** add `RemoteAlignmentService`, `AlignmentUploadCoordinator` and a persisted Codable job record in Application Support. Copy selected provider files into private local staging before upload; security-scoped URLs alone do not survive app termination. Stream hashing off the main actor. Persist part files/task identifiers before submission and reconcile URLSession tasks on relaunch.
6. **iOS lifecycle:** use background URLSession delegates with SwiftUI app delegate integration for transfer callbacks. System termination and user force-quit are different: do not promise uploads continue after force-quit. On next launch resume/reissue missing parts; processing already started on AWS continues independently. Store job capability tokens in Keychain; never persist signed URLs as durable credentials. On loss of token show that the old job cannot be recovered; do not guess another job or rerun automatically.
7. **Import result:** download SRT to staging; verify checksum/bytes/UTF-8, parse using `TranscriptParser`, enforce duration checks (parser currently does not), then use `MediaImportService` with the local staged audio. Introduce a defaulted persisted review flag and show a warning for reviewed output. Existing file copy + SwiftData save are compensated operations, not a single filesystem/database transaction: roll back both on failure. Preserve staging until successful save; reconcile orphan staging after a crash. Leave the job available if import fails; do not rerun inference.
8. **Product UI:** separate optional “Align audio with TXT” action from existing local timed/TXT import. Expose upload, processing, cancellation, failure, review and expiry states. Never imply server-generated word highlighting or cloud library storage. Retain ordinary import offline.
9. **Test-release gate:** job-capability isolation tests, one-task admission/race tests, no raw text in logs, measured cost/limits, relaunch import, cross-file cleanup and reviewed-output warning all pass. Update `knowledgebase/CHANGELOG.md` and `DECISIONS.md` in the implementation PR; update `PROJECT.md` when cloud capability actually changes the shipped boundary.

Public testing and the 60-minute duration limit are resolved. Do not add sign-in as a prerequisite for this test implementation. Account authentication, per-user quotas, production abuse protection and recovery belong to `FUTURE_IMPROVEMENTS.md`. Public API throttling and these global counters bound admitted work but do not constitute comprehensive abuse protection: presigned upload replay/storage abuse remains a test-release limitation. Provide an operator `ACCEPT_NEW_JOBS` kill switch checked by create, upload-URL renewal and start; already running jobs can finish or be cancelled separately. Do not mistake a budget alarm for an automatic spending cutoff.
