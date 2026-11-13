## 2026-11-13 — Queue-based cloud book alignment

- Add the native three-step alignment wizard for audio/audio ZIP plus UTF-8 TXT or EPUB, local
  validation, client-built ZIP ≤100 MB, direct signed S3 upload, separate queue submission,
  API-driven progress, durable draft/request recovery and verified book download/import.
- Add owner-keyed DynamoDB requests/history, stream outbox + scheduled lease recovery, SQS and
  a serial Fargate book worker. Recheck actual pinned input size/hash; prepare EPUB and joined
  audio, align without the legacy five-minute duration cap, and publish subtitles/word timings.
- Replace operator pilot HTTP routes with queue-only book routes. Keep legacy resources during
  migration; public-test/paid APIs are unchanged. Record architecture/workflow changes in
  DECISIONS.md, PROJECT.md and docs/CLOUD_BOOK_ALIGNMENT.md. A new image and normal deployment
  are required; local tests do not establish long-book acoustic quality or live AWS acceptance.
- Local validation after syncing main: 291 iOS unit tests and the wizard relaunch UI test pass;
  unsigned device Release builds. Backend: 120 tests (2 optional skips); aligner: 31 tests; new book worker:
  7 tests including a 306-second fake-engine pipeline, S3 publication and lease-loss fencing.
  All CDK assertions, 46 Cloud Control/benchmark tests and 32 CI/asset-packaging tests pass.

## 2026-11-13 — Forward model/reasoning choices and show translation routing

- Snapshot the selected provider mode, model and supported reasoning effort at the start of
  contextual translation/word explanation. Pass model and reasoning through both cloud payloads;
  expose those settings in subscription mode while keeping personal prompts/key private.
- Accept optional paired `model`/`reasoning_effort` fields in both backend assemblies, validate an
  app-aligned allowlist before admission, retain them through subscription queue execution and
  forward them unchanged to OpenAI. Preserve old-client defaults, server output/time caps,
  admission controls, and no automatic paid retries. Settings participate in idempotency hashes.
- Label active contextual requests in preview/dictionary/learning/word disclosure as direct
  OpenAI or cloud backend with model/effort; label Apple translation on-device. Labels use the
  same captured settings as the request, including when preferences change while it is running.
- Update architecture decisions, project workflow and API/setup docs. No deployment, live model
  inference, or operator translation-mode wiring is claimed by this change.

## 2026-11-11 — YouTube import with synchronized transcripts

- Add YouTube URL import and a Safari Share Extension with confirmation before library insertion.
  Store cue text/times locally and stream video through the embedded YouTube player. Reuse
  native reading, vocabulary indexing, translation and dictionary selection.
- Report missing/inaccessible captions; preserve cue timing without inventing word timing or
  offline phrase audio. Simulator Debug and paid-team Release use App Group handoff;
  Personal Team device Debug retains in-app URL import and empty entitlements.
- Update architectural decisions, project workflow and docs/YOUTUBE_IMPORT.md. No Apple
  provisioning changes, release publication or deployment are included.
- Verify both real Safari Share and in-app URL import on iPhone 17 Pro / iOS 26.5 with
  six English cues from `jNQXAC9IVRw`, including library insertion and online playback
  with native cue highlighting. All 283 unit tests, four extractor tests and 31 CI tests
  pass; unsigned device Release compiles. Broader content coverage and paid-team device
  signing remain unverified.

## 2026-11-11 — Automatically renew the built-in library session

- Replace manual access-token pasting with operator username/password sign-in in library settings.
  Confirm the backend operator profile before saving access/refresh tokens in device-only Keychain;
  never persist the password or export session credentials in library backups.
- Refresh before expiry and retry a library GET once after 401. Share concurrent refreshes, retain
  credentials on transient network errors, clear revoked sessions, and prevent late refresh/login
  responses from restoring a signed-out session. Sign-out clears locally and revokes the refresh token.
- Existing access-only installations need one password sign-in; their old manually pasted token
  cannot be converted into a refresh token. No backend redeployment or token lifetime change.
- Record deployed operator release 228 and its six passing public boundary checks; authenticated
  post-deployment/model checks remain pending. Update decisions and project workflow for native
  private-operator library login. Apple subscription
  sessions and personal OpenAI keys remain separate.

## 2026-11-11 — Personal Team device signing

- Debug builds now use an empty entitlement file so local device provisioning does not request the unsupported Sign in with Apple capability. Release builds retain the native capability.
- Documented the paid-team requirement for Release and native Apple reauthentication/recovery testing.
- Signing configuration decision recorded in DECISIONS.md; project purpose and boundaries are unchanged, so PROJECT.md is unchanged.

## 2026-11-11 — Prepare private backend migration from Bedrock to OpenAI

- Replace the operator Qwen Converse provider with the existing OpenAI Responses integration,
  defaulting to GPT-5 mini/minimal reasoning like the app, strict JSON and server validation.
- Preserve one-submission idempotency/unknown outcomes and the 2048-token cap; use an 18-second
  operator timeout without changing the subscription worker's 45-second default.
- Add a same-project Stockholm Secrets Manager ARN to CDK/dashboard configuration, scope key
  read permission to the translation handler, and replace Bedrock readiness with secret metadata.
  Health/login/audio do not fetch the provider key. No secret enters source or browser settings.
- Update rollout/setup instructions, architecture decisions and project status. Live OpenAI
  acceptance and deployment require a configured secret and a new verified release; neither is
  claimed by this implementation. Existing unknown Bedrock requests are not retried.

## 2026-11-11 — Curated downloadable book library

- Added an operator-authenticated catalog and short-lived S3 download links, a native library
  screen, and a separate Keychain access-token setting. Downloaded ZIPs are size/hash checked
  and passed to the existing complete-book import wizard.
- Added retained private storage infrastructure and a CRC/SHA-256 catalog preparation helper
  for complete audiobook packages. See [publishing guide](../docs/BOOK_LIBRARY.md).
- Decisions and project overview updated for the curated-library workflow.

# Project changelog


## 2026-11-11 — Recover the dashboard after the first operator deployment

- Confirm release v0.0.1-backend.216 deployed both operator stacks successfully. The post-deployment
  warning came from selecting an empty, undeployed subscription foundation before the operator API.
  Skip undeployed/empty endpoints while retaining HTTPS, Region and hostname validation.
- Treat only UUID-named JSON files as operation records. CDK's `<id>.outputs.json` remains available
  as evidence but no longer breaks startup recovery or `/api/state` sorting after deployment.
- Validation: all 42 control-panel tests pass, including both regressions. The live dashboard is
  restored and six safe HTTPS smoke checks pass. Both stacks are CREATE_COMPLETE; unauthenticated
  `/v1/health` and `/v1/me` return 401. The console-created operator does not yet exist; authenticated
  application functionality remains unverified. No repeat deployment is needed for these panel fixes.
- No architectural decision changed. PROJECT.md records the deployed private pilot and preserves
  the undeployed subscription/public-test and unconnected iOS boundaries.

## 2026-11-11 — Complete CDK bootstrap and accept standard manifest stack names

- After explicit approval of the persistent AdministratorAccess execution role, create Stockholm
  CDKToolkit v32 with same-project trust, AWS-managed key choice and termination protection.
  Bootstrap must run from a neutral directory so the default alignment app is not synthesized first.
- Fix plan validation for real CDK manifests that omit `properties.stackName`: use the artifact ID,
  matching the pinned CDK cloud-assembly API. Keep explicit stack-name and project/Region checks.
- Retain complete first-deployment diffs up to 500 KB with a bounded 750 KB operation log; continue
  rejecting larger truncated plans. Keep JWT/AWS-key redaction before persistence.
- Validation: 40 control-panel tests pass, including complete initial diffs, oversized rejection,
  redaction, absent-name preparation and rejection of an
  explicit unexpected stack or foreign environment. Live toolkit status is CREATE_COMPLETE and
  all readiness checks passed after bootstrap. The final live plan retry was blocked by an expired
  AWS login session; no ready plan or application deployment is claimed.
- No architectural decision changed; PROJECT.md updates operational readiness and the guide records
  the tested bootstrap invocation.


## 2026-11-10 — Explain missing CDK bootstrap during plan preparation

- Reuse the same missing-CDKToolkit check in readiness and first-stage preparation, replacing the
  opaque `Operation unavailable: ValidationError` with a one-time bootstrap instruction and guide link.
  Other validation/authorization errors retain their own classification; no bootstrap is automatic.
- Validation: 37 control-panel tests pass, including missing-stack handling, unrelated service errors
  and stopping preparation before asset building. No architecture or project overview changed.
- Reviewed the pinned CLI bootstrap template for Stockholm. Execution was rejected by automatic
  approval review because its persistent CloudFormation role uses AdministratorAccess without
  explicit approval of that IAM change. CDKToolkit remains absent; no bootstrap creation is claimed.


## 2026-11-10 — Execute and retain the private Polish audio benchmark

- Run the published pilot image on native Stockholm Fargate: one strict failure, then three
  successful cold runs in the existing keep-untimed-words mode (113–124 seconds per 300-second audio).
  Preserve all 626 words, 15 untimed-word flags and identical SRTs. Conservative peak memory is
  1,173.69 MiB; calculated task/IPv4 cost across all four attempts is $0.02748, excluding other services.
- Keep actual inputs/provenance/raw results/video outside Git; generate an image-matched report.
  Record the user's acceptance and explicit manual-check waiver without claiming listening review.
  Point Cloud Control at that report and image; both readiness checks pass after restart.
- Confirm temporary stack DELETE_COMPLETE and retain ECR. Add the stack Purpose tag to the CLI
  deployment example and expose the existing review-required mode explicitly in measurement helpers.
- Validation: live native runs, report validation, teardown/ECR checks, harness regressions and
  workflow lint. DECISIONS.md records scoped user acceptance; PROJECT.md records readiness boundaries.
  Application bootstrap/API deployment have not been performed.


## 2026-11-10 — Limit first-stage audio to a Polish five-minute pilot

- Restrict operator audio admission to Polish and enforce actual ≤300-second audio in the worker
  and cue validation. CDK applies the same pilot scope to alignment functions and worker tasks.
- Require an image-matched three-run, 300-second Polish report in both Cloud Control and CDK;
  retain reviewed quality, runtime, memory and cost gates. Stage-two requirements remain unchanged.
- Explain the scope and missing-evidence requirements in the dashboard and operational guides.
  DECISIONS.md and PROJECT.md record the narrower initial release boundary.
- Add an independent bootstrap-free private Fargate benchmark plan, real engine driver/controller,
  input/driver checksums, failure-evidence preservation, per-task time limits and guarded cleanup.
  This provisions no API/service and does not bypass the application benchmark gate.
- Validation: boundary/language/report tests, failure/privacy harness regression, all four CDK suites
  and CloudFormation ValidateTemplate pass. Native cloud execution/listening acceptance remain pending.
  The ARM-host x86 local experiment was stopped after 26.1 audio seconds took 213 seconds; it is not
  a completed performance/cost benchmark. No accepted report or API deployment is claimed.

## 2026-11-10 — Complete the Linux audio worker dependency lock

- Pin Whisper's Linux/x86_64 Triton dependency to 3.3.1 with the official CPython 3.12 wheel hash.
  This fixes strict Docker builds failing on unpinned `triton>=2`; CPU-only PyTorch and hash enforcement remain unchanged.
- Add a real Linux dependency-resolution/hash check to backend CI, with pip caching for the worker
  and billing locks. It performs a dry run so worker versions do not replace backend test dependencies.
- Validation: strict Linux/amd64 Docker build succeeds; pip check reports no broken requirements.
  Offline runtime checks pass as UID 65532: CPU-only PyTorch/torchaudio, multilingual Whisper base
  loading, model checksum and worker import. Three worker-adapter tests, workflow lint and diff checks pass.
  This is a runtime smoke check, not the real-audio quality/cost benchmark.
- No architectural decision or project overview changed.

## 2026-11-09 — Reuse one simulator for exhaustive unit-only CI

- Main push and other runs without UI coverage now overlap simulator boot with compilation, then
  discover and execute the complete frozen unit suite on that same runner/device. Remove the
  duplicate unit consumer boot and artifact handoff. UI-selected PRs retain all matrix shards.
- Preserve exact discovered-method/count checks, revision/Xcode/architecture binding, diagnostics,
  25-minute budgets, one discovery-infrastructure retry and no automatic actual-test retries.
  The aggregate accepts a skipped matrix only after successful combined unit execution and Release.
- Evidence: main CI 42710302925 spent 128 s compiling and 561 s booting/discovering before a second
  consumer boot. Local combined execution passes all 273 unit tests with zero skips; 31 CI regression
  tests cover reuse, retry boundaries, count enforcement and required-gate failure cases. Hosted
  speed improvement remains to be measured; no fixed completion-time claim.
- DECISIONS.md records the unit lifecycle change; PROJECT.md and the CI runbook describe the new path.

## 2026-11-09 — Readable versioned backend releases

- Produce annotated backend versions such as `v0.0.1-backend.123`, using tracked backend/VERSION and
  the successful main CI run number. Keep the full tested SHA and CI run URL in immutable metadata.
- Update Cloud Control fetching/listing/verification and version labels while retaining legacy tag
  rollback and first-stage operator compatibility. No old tag is moved, renamed or deleted.
- Add disposable local-origin coverage for valid refspec fetching, metadata/source binding,
  successful-main CI verification, immutable reruns, invalid versions and legacy rollback.
- Validation: all 34 control-panel/local-Git tests pass, including real fetch refspecs and producer
  reruns; shell/JavaScript syntax and diff checks pass. No remote release tags are minted by tests.
- DECISIONS.md records the naming and verification contract; PROJECT.md and publication guides
  describe version selection. No AWS resource, deployment behavior or iOS product behavior changes.

## 2026-11-09 — Publish the private first stage through Cloud Control

- Implement an independent operator CDK assembly with console-created Cognito password/SRP login,
  JWT/live-session checks and permanent subject binding. Add direct regional Qwen3 translations/
  word explanations, bounded inference without SDK retries, transactional daily admission and
  24-hour idempotent result recovery; no Apple, subscription or SQS inference dependency.
- Protect reused alignment routes with operator authentication; retain private S3, Fargate workflow,
  admission/recovery logic and real image/benchmark gates. Pin verified availability zones for
  lookup-free assembly. Add one-week logs, token/latency/error metrics and SNS-linked alarms.
- Add first/second-stage dashboard settings, compatible-tag filtering, real readiness checks and
  post-deployment Cognito/API outputs. Build an Apple-free hash-locked Linux asset; provide local
  password-login and explicit worker-image build/publish helpers with a restricted Docker context.
- Document publication and remaining prerequisites in OPERATOR_CLOUD.md. Existing tags cannot publish
  the new assembly; bootstrap, an actual worker image and reviewed measurements remain absent.
  No bootstrap, worker publishing, cloud deployment or successful paid inference is claimed.
- Validation: all 99 backend tests pass with real local DynamoDB, including concurrent replay;
  25 dashboard tests and all three CDK assertion suites pass. Full two-stack CLI synthesis runs
  without lookups; AWS ValidateTemplate accepts both templates (audio in equivalent compact JSON).
  Browser checks confirm first-stage settings save, Apple fields are hidden, incompatible tags are
  explained, and real readiness shows the missing bootstrap/image/measurements. No iOS behavior changed.
- DECISIONS.md records operator authorization and direct-call recovery; PROJECT.md describes the
  implemented publication mode and remaining release prerequisites.

## 2026-11-09 — Bedrock model selected for Polish/Russian

- Select regional Bedrock Qwen3 235B A22B Instruct 2507 for stage-one translation/explanation;
  document model ID, language rationale, IAM-based access and Stockholm Standard pricing.
- Read-only access checks pass; live evaluation is blocked by AWS project verification. Do not
  claim measured quality, schema compliance, latency or deployed provider integration.
- Update rollout, DECISIONS.md and PROJECT.md; runtime migration remains to be implemented.

## 2026-11-09 — Two-stage cloud rollout plan

- Document a private single-operator backend first: manual Cognito username/password user, protected
  API, direct model calls without SQS, authenticated alignment and monitoring. Move Apple identity,
  purchases, customer isolation and subscription accounting to stage two.
- Record the 30-second HTTP API deadline, minimal idempotency recovery, retained alignment image/
  measurement gates and required new assembly/dashboard mode. No deployment or runtime change.
- Inspect the live eu-north-1 Bedrock catalogue/profiles and document regional candidates, access
  caveats and a six-language evaluation. No inference or provider migration performed.
- DECISIONS.md records the new rollout boundary; PROJECT.md reflects its planned status. Link the
  superseded paid-backend plan and current dashboard runbook to the new plan.

## 2026-11-09 — Cloud dashboard release selection and setup errors

- Replace hidden release-tag autocomplete suggestions with an explicit dropdown and a visible count of fetched tags. Preserve the selected release during status polling.
- Validation: JavaScript syntax and diff checks pass; live dashboard shows the fetched tag and retains its selection during polling.
- Preparation with account/profile-only settings now reports missing deployment parameters and the settings section instead of KeyError. A regression test confirms validation stops before GitHub/AWS work; all 21 control-panel tests pass.
- No architectural decision or project overview changed.

## 2026-11-02 — Restore ARM XCTest execution after Intel discovery timeouts

- Restore matching macos-26 arm64 producer/consumer runners. In main CI 41528072926 the Intel simulator reached ready state, but both unit-discovery attempts exceeded 240 seconds; PR #77 UI discovery also timed out before its producer job was cancelled. More memory did not establish a working Intel path.
- Preserve all event/path-selected coverage, eight UI groups, 25-minute execution budgets, artifact integrity and the full successful-main tag gate. No actual test is retried or skipped to bypass the failure.
- Validation: workflow lint and diff checks pass; earlier full local arm64 execution passed all 273 unit tests. Hosted ARM CI 41532537900 passed backend contracts, all 273 unit tests, device Release and the strict aggregate; UI was intentionally not selected for the CI-only diff. DECISIONS.md supersedes the Intel capacity trial, PROJECT.md and the CI runbook reflect restored architecture. No deployment or manual tag.

## 2026-11-02 — Preserve main CI for verified tags

- Give each non-PR CI revision an event/SHA-scoped concurrency group; only updated PR checks cancel their predecessors. A new main merge can no longer cancel the previous commit's in-progress or pending release-verification CI.
- Diagnosis: the main push for 8daf14b was cancelled, followed by a skipped tag workflow; the newer 3b28773 CI was still running. Tag creation correctly requires full successful push CI, has explicit contents:write, and no repository tag rulesets were reported. Preserve the success gate and immutable/idempotent tag script; do not manually create tags.
- Validation: workflow lint and diff checks pass. DECISIONS.md records release concurrency; PROJECT.md and CI/operator runbooks describe the per-commit verification workflow. Live tag creation remains pending successful main CI.

## 2026-11-02 — UI tests only for iOS-changing PRs

- Select UI discovery/execution only for PRs into main whose merge-base diff changes App code/resources, UI scenarios, project/dependency inputs or the iOS bootstrap. Documentation, backend, agent setup, CI tooling and unit-only PRs keep unit/backend/Release checks without scheduling UI groups; this includes the Toolkit PR.
- Resolve scope from full Git history with both sides of renames. Invalid/missing history blocks CI instead of producing a false successful UI omission. Preserve the strict aggregate and verified-main tag gate.
- Validation: 23 CI-helper/scope tests and workflow lint pass, including real Git merge-base and rename cases. DECISIONS.md and PROJECT.md record the changed coverage policy; CI/operator runbooks are updated. No deployment or manual tag.

## 2026-11-02 — AWS Agent Toolkit setup

- Add AWS new-experience guidance for Codex, Claude Code, Cursor and Gemini CLI while preserving existing project instructions. The selected project Region is `eu-north-1`; local toolkit connections use the `default` CLI profile and the toolkit service in `us-east-1`.
- Point Claude/Gemini/Cursor to the existing AGENTS.md contribution rules; keep AWS-specific blocks consistent. Ignore the local `typescript` terminal recording without publishing or deleting it.
- This configures development tools only; no application resources are deployed. No architectural/product decision or project overview changed; DECISIONS.md and PROJECT.md are unchanged.

## 2026-11-02 — Hosted XCTest capacity and timing fixes

- Split all 59 PR-only UI methods into eight 7–8-case groups instead of four 14–15-case groups, with a 25-minute per-job budget for boot, Xcode launch, tests and diagnostics. The previous hosted ui-3 run was cancelled while its last scenario was still executing; no case is omitted or retried automatically.
- Use matching standard macos-26-intel producer/consumer runners with 14 GB RAM for XCTest, retaining an independent device Release build. This provides resource headroom for the observed first-app launch timeout; hosted validation remains necessary and no claim of a proven memory-exhaustion cause is made.
- Extend the screen-awake audio fixture from two to sixty seconds so natural completion cannot race intermediate pause/interruption assertions; preserve explicit near-end completion and close checks with bounded state waits. Wait for the actual chapter row before selecting it in both book and legacy reader regressions.
- Validation: 17 CI-helper regression tests and workflow lint pass; the screen-awake integration and both book/legacy chapter-progress UI scenarios pass locally. Clean x86_64 XCTest build-for-testing succeeds; hosted execution on the new runner remains pending.
- DECISIONS.md records the capacity/timing contract; PROJECT.md and CI/operator runbooks reflect eight PR-only UI groups. Main still requires backend, all unit tests and Release without UI discovery/execution. No deployment or manual tag.

## 2026-11-02 — Document-picker UI coverage across tabs

- Fix the remaining hosted ui-3 failure: the file dialog opened in Recents, which does not expose the Browse-only internal container expected by the test. Identify the document navigation bar by its Cancel/More actions and explicitly exercise both Recents and Browse while opening/cancelling media and subtitle selection.
- Validation: the targeted iOS regression passes locally with explicit Recents/Browse navigation and both open/cancel/return paths.
- Preserve both picker checks and all event-selected CI coverage. The PR-only UI policy and main unit/backend/Release tagging gate remain unchanged; no project overview change or deployment is involved. DECISIONS.md records the test-selection contract.

## 2026-11-02 — UI coverage on PRs into main only

- Run all UI methods only for pull requests targeting main. Post-merge main CI, manual runs and reusable publishing runs discover/run all unit tests without launching UI discovery or scheduling UI shards.
- Keep backend contracts and device Release compilation required for successful main CI and automatic verified tags. The aggregate requires every event-selected shard to pass; failures/cancellations cannot become successful skips.
- Validation: 17 CI-helper regression tests and workflow lint pass; real local XCTest unit-only discovery produces exactly one shard containing all 273 unit tests, without UI discovery.
- Add explicit unit-only planning/discovery coverage and update IOS_CI/CLOUD_CONTROL runbooks. DECISIONS.md records this release policy; PROJECT.md reflects the revised supported workflow. No deployment or manual tag accompanies this change.

## 2026-11-02 — Reliable XCTest discovery bootstrap

- Fix the failed build-once CI discovery: Xcode returned success after the UI runner lost testmanagerd, leaving only unit methods plus a UI-bundle placeholder. Keep rejecting this partial coverage.
- Prewarm isolated fresh simulators, enumerate unit/UI bundles separately, and allow one bounded retry only for discovery bootstrap loss/timeout. Actual test methods still execute once; unknown discovery errors remain fatal. User-selected simulators are never deleted.
- Separate compile/discovery/archive workflow steps and retain both discovery manifests and xcresults. Invalidate stale plans on failed discovery; require matching revision/toolchain before packaging.
- Give hosted first-boot system migration a separate 600-second readiness budget: observed 180-second failures were still inside CoreLocation migration. Do not restart migration on a new device after a readiness timeout; retain retries only for XCTest discovery after readiness.
- Make the back/reopen progress scenario seek with the exact +10-second transport action. Hosted XCTest dragged the slider to 11.182 seconds and correctly restored that position, so the hard-coded 0:10 slider expectation was flaky; preserve exact resume/reset assertions for both readers.
- Use one stable file-import presenter for legacy media/subtitle selection and exercise opening/cancelling both choices in the same form. Hosted failure snapshots showed the form still visible without a picker. Wait for dictionary row disappearance and the empty section after deletion; the recording showed successful deletion before the stale immediate existence assertion failed.
- Check the complete compiled test-target catalogue before target-specific filtering, so adding a new target cannot silently omit its tests from CI.
- DECISIONS.md records the bootstrap contract; the existing PROJECT.md CI workflow/boundaries remain unchanged.

## 2026-11-01 — Exhaustive iOS CI shards

- Replace the monolithic timed-out iOS job with one portable test build, one unit shard, four UI shards on separate runners, and an independent device Release build. Keep the required `Build and test` aggregate and require every job for successful main tagging.
- Discover compiled XCTest identifiers, assign every method exactly once, bind the artifact to commit/Xcode/architecture, preserve file permissions with tar, and reject empty/incomplete result counts. Bound individual test duration and save per-shard diagnostics without automatic retries or omitted tests.
- Update UI scenarios for the longer settings form, Book actions/New words and library completion counts, preserving cancellation and completion coverage after removal of older reader controls.
- Record CI/artifact/tagging decisions in DECISIONS.md and the supported operator workflow in PROJECT.md. See docs/IOS_CI.md for reproduction and diagnostics; no deployment or manual release tag is performed.

## 2026-11-01 — Stockholm cloud deployment region

- Switch cloud foundation/billing/translation and alignment assemblies, local dashboard, regional endpoint/secret validation and setup examples to `eu-north-1` (Stockholm), matching the operator's AWS profile. Reject the previous Frankfurt target and cross-region secret/API inputs before deployment.
- Update alignment benchmark/cost instructions for Stockholm; measured quality, runtime and regional pricing approval remain pending. No resources are deployed or moved by changing this target.
- Read-only AWS template validation confirms `AWS::Budgets::Budget` is unsupported in Stockholm. Omit that resource from regional alignment templates and require separately configured account-level budget alerts in the launch runbook; admission caps/quotas/operational alarms remain intact.
- Validation: 20 control-panel tests, CDK type/dev/prod/alignment assertions, full prod CLI synthesis, three live AWS ValidateTemplate checks, and live dashboard reads in Stockholm pass. All prod stacks report NOT_DEPLOYED; no bootstrap, deployment or paid API request was run.
- DECISIONS.md records the superseding region choice; PROJECT.md reflects the operator workflow. Local profile/dashboard configuration is updated separately and remains outside Git.

## 2026-11-01 — Local AWS production control panel

- Add a loopback Russian-language dashboard for real prod stack/release/CloudWatch status, CI tags, reviewed deployment plans, manual deploy/rollback and local history. AWS profiles stay on the computer; startup does not deploy infrastructure.
- Tag successful main push CI runs as immutable annotated `backend-<CI run number>-<short SHA>` releases through a separate post-CI workflow. Failed/PR/publishing runs cannot tag; no automatic deployment follows.
- Build exact tagged source into a single-use assembly; enforce account/region, successful main CI, baseline/file/config freshness, serialized operations and explicit target confirmation. Rollback deploys an old code tag with reviewed current configuration, without restoring data.
- Add real production smoke/authenticated/opt-in inference suites. Missing tokens are skipped coverage; UUIDs persist before submission and lost responses recover without automatic retries. No live AWS deployment, prod probe or paid call was performed during implementation.
- Validation: 20 isolated control-panel tests, JavaScript/Python/shell checks and browser QA pass. After merging current main, 272 iOS unit tests and two selection/audio UI scenarios pass. No AWS deployment or paid probes were run.
- DECISIONS.md records local control/deployment/tag choices; PROJECT.md adds the operator workflow. Setup and acceptance limits are in docs/CLOUD_CONTROL.md.

## 2026-11-01 — Complete undeployed paid-cloud workflows

- Add durable context/word translation admission, atomic monthly allowance and global/frequency/concurrency limits, stream/SQS dispatch, one-attempt provider submission, failure/unknown-outcome settlement and independent content cleanup. Effective policy IDs bind model, prompts, schemas and limits; unapproved products/admissions remain disabled.
- Add iOS Apple/Cognito login with PKCE, device-only session refresh/sign-out, StoreKit purchase/restore/unfinished recovery and subscription settings; persist request keys before submission and recover by owner/key after relaunch. Keep personal API key/model/prompts as a separate mode, with no fallback after subscription errors. Local reading and saved dictionary remain independent.
- Add verified Apple identity revocation/deletion events, durable session floors and fresh-login recovery. Cloud account deletion supports native Apple revocation and an explicit manual fallback when Apple is unavailable; deletion does not cancel subscriptions.
- Add scoped account-only `/v2/alignments`, separate job allowance, transactional start/settlement, deletion-aware cleanup and a pinned-image/six-language benchmark gate. Preserve existing media/version/worker/global limits. Fix the shared cancellation transaction's unused placeholder, rejected by real DynamoDB for started jobs.
- Add isolated AWS/cryptographic/client/UI tests, DynamoDB Local concurrency coverage in CI, public iOS configuration generation and the no-deployment operations/TestFlight/production acceptance runbook. Actual Apple/AWS acceptance, publishing, operating-policy approval and real alignment benchmarks remain unexecuted release gates.
- Validation: 86 backend tests with DynamoDB Local (including concurrent admission), 26 existing aligner tests, 269 iOS unit tests, four targeted UI flows and an unsigned iOS device Release build pass. Dev/prod CDK assertions and full CLI synthesis, the hash-locked Linux asset build, packaged-source comparison and public configuration generation pass. Real Apple/AWS/provider acceptance remains external.
- DECISIONS.md records identity, allowance, uncertain outcomes, caching, retention and independent paid alignment boundaries. PROJECT.md reflects the configuration-gated workflow; no deployment or endpoint is added to a normal build.


## 2026-11-01 — Paid cloud account and subscription foundation (undeployed)

- Add independent dev/prod Cognito + Sign in with Apple and billing infrastructure, account-issued StoreKit tokens, subscription sync/status and account tombstones. Keep personal-key translation as a separate existing mode.
- Verify Apple signatures through the official SDK, reconcile live subscription state, bind purchase chains atomically to one account, and handle expiry, grace and revocation. Persist verified notification metadata before acknowledgment, with stream retries, dead letters and scheduled reconciliation.
- Add backend and CDK acceptance tests, CI installation, a hash-locked Linux Lambda build and an operator runbook. No deployment, iOS subscription UI, inference or approved tariff/quota is included; compute entitlements remain disabled.
- Validation: 44 backend tests, 26 local-aligner regression tests, dev/prod CDK assertions, hash-locked Linux x86_64 asset build and development CLI synthesis pass. Real Apple sandbox and AWS runtime acceptance remain outstanding.
- DECISIONS.md records the adopted server boundaries and development freshness settings. PROJECT.md adds the undeployed foundation to the repository map; shipped local/BYOK workflows remain unchanged.


## 2026-11-01 — Selection across book pages

- Add a chapter-wide selection overlay to book pages. Long press a word, then drag either handle to the left/right edge and hold briefly to continue selecting on adjacent pages, in either direction.
- Preserve one source-character range across transitions, highlight its visible portion, and offer translation, dictionary saving and copying from a compact selection toolbar. Dictionary context and audio resolve against the entire original chapter, including every selected cue.
- Selection pauses audio and suspends following; following again or leaving the reader clears selection. Vertical layout keeps its native selection. Handle adjustments are available to VoiceOver.
- DECISIONS.md records global selection ownership and edge transitions; PROJECT.md includes the cross-page selection workflow.

## 2026-10-31 — Compact reader controls

- Add a saved Text layout choice in ⋯: Book pages or Vertical scrolling. Both readers preserve the current document offset when switching; bottom Follow remains available in either layout.

- Remove the Full text / Track transcript picker and select synchronized track text automatically when available, falling back to full text otherwise.
- Remove the reading-vocabulary disclosure from the reader. Move New words highlighting into the ⋯ resource menu with a shared saved preference.
- Remove the reading percentage from the player and reduce player padding, spacing, page-navigation height and bottom text inset to give more room to the book.
- DECISIONS.md records automatic text selection and the saved highlighting preference; PROJECT.md reflects the simplified reading controls.

## 2026-10-31 — Stable page turns and whole audio phrases

- Replace the rebuilding SwiftUI page window with a native scrolling page controller that retains neighboring pages and defers content refreshes until transitions settle. Manual gestures, cancelled swipes and audio-driven page changes share the same controller lifecycle.
- Keep timed subtitle cues whole on a page so audio always selects the page containing the entire phrase. Untimed text uses sentence boundaries. A phrase larger than the viewport occupies one page with vertical overflow instead of being split or clipped.
- Return Follow audio to the bottom reader controls, with stable footer geometry and a compact horizontal arrangement in landscape. Update the pagination decision and supported reading workflow.

## 2026-10-31 — Model choice and configurable reasoning

Settings adds GPT-6.1 Terra and GPT-6.1 Sol, and uses full names for GPT-5 mini, GPT-5 nano and GPT-6 Luna. A reasoning-effort picker offers only levels supported by the selected model. The setting applies to contextual translations, word explanations, listening distractors and API-key checks. Explanation caches separate reasoning settings, and portable library backups include the optional preference while accepting older backups. Requests with reasoning get larger bounded output budgets and timeouts. Architectural decisions are recorded in DECISIONS; project purpose and workflow boundaries are unchanged.
## 2026-10-31 — Dictionary-grounded listening answers

Listening uses the saved dictionary translation verbatim as its correct answer and only samples entries with a translation and audio. The model generates only distractors, guided by the saved answer. The prompt analyzes the entire phrase, picks its two hardest independent meaning-bearing elements, and combines two incorrect meanings for each into four 2×2 variants; single-word/indivisible expressions use four single-element variants. Decisions and the project workflow were updated; levels and progress tracking remain unchanged.


## 2026-10-30 — Standalone listening practice

Practice now offers up to ten random dictionary phrases with available selected-fragment audio in the active source language, regardless of level or cooldown. Cards show only playback and five target-language translations, with immediate correct-answer feedback. Requests contain only the saved phrase and source/target languages; the existing configured cloud provider generates one correct answer and four semantic distractors. Selected-fragment playback retains automatic 0.5-second padding and manual overrides. Sessions are memory-only and never change levels, cooldowns, regular checkpoints or activity history. Decisions and project workflow are updated below in their respective documents.

## 2026-10-30 — Book-style reader pagination

- Replace the unwrapped horizontal transcript with horizontally swiped book pages in both readers. Text wraps within each page; timed subtitle line breaks become spaces so cue boundaries no longer fragment prose. Untimed books retain their paragraphs.
- Recalculate page boundaries for the available viewport and font size, preserving the reading position. Audio following selects the page containing the current cue; manual page turns suspend following. Page-local selections map back to the original chapter for contextual translation and phrase audio.
- DECISIONS.md records pagination and offset preservation; PROJECT.md reflects the paginated reading workflow.

## 2026-10-30 — Paid cloud backend implementation plan

- Add [the paid cloud backend plan](../docs/PAID_CLOUD_BACKEND_PLAN.md) covering account identity, Apple subscription verification, server-operated translations, durable request/usage accounting and later integration with the existing alignment backend.
- Record proposed API/data boundaries, rollout order, failure/recovery cases and unresolved tariff, quota, BYOK and retention choices. Link the plan from the alignment architecture and future-work backlog.
- Documentation only: no implementation, deployment, subscription configuration or tariff approval. DECISIONS.md indexes the proposal without replacing current decisions. No adopted architectural/product decision, shipped workflow or project overview changed; PROJECT.md is unchanged.


## 2026-10-30 — Horizontal transcript scrolling

- Timed transcript lines in the playback reader remain on one line and can be scrolled horizontally; playback follow keeps the active cue's beginning visible. Full-text reading keeps its existing wrapping.
- No architectural/product decision or project-overview change was required.

## 2026-10-29 — Responsive audio during selection translation

- Move synchronous audio-session setup and teardown off the UI executor so tapping Play in a selection's dictionary/translation popup cannot block translation rendering and other interface actions while the media server responds. Playback starts only after session activation; pause, close and source replacement invalidate pending starts and errors. Rate changes and seek completions cannot bypass activation.
- Enqueue player time, end and seek callbacks on the UI executor before reading or changing playback state, retaining stale-event checks and safe chapter transitions. Repeated play requests coalesce while activation is pending; explicit Play still resumes after a system interruption.
- Add a delayed translation UI fixture and cover selecting text, adding to the dictionary, playing audio before translation completes, saving the result, closing the popup and resuming the reader. Unit coverage holds audio activation open and verifies responsive pause/close, stale-result rejection, failure/retry and seek/rate gating.
- Verification: all 241 unit tests and the selection translation/audio and natural chapter-transition UI scenarios pass on the iOS 26.5 iPhone 17 Pro simulator after integrating the current Now Playing controls. Audio-boundary editing UI also passed before integration. The original physical-device stall has not been measured or reproduced with a device stack trace.
- DECISIONS.md records audio-session execution and callback handling. No project purpose, supported workflow or major boundary changed, so PROJECT.md is unchanged.

## 2026-10-29 — System audio controls and easier reading/practice

- Publish book/chapter and phrase playback to iOS Now Playing for the Lock Screen, Control Center and supported Dynamic Island media surfaces. System play/pause, ten-second skips and scrubbing control the current player; chapter commands use the book coordinator and phrase timelines stay relative to their clip. Only one app player owns the session. Interruptions and disconnected headphones pause playback.
- Tap the practice card to reveal the answer and tap its translation to hide it again. Show a hand/tap hint before reveal and explicit left=Right, right=Wrong swipe hints afterward; answer buttons and undo remain available.
- Use compact landscape playback panels in both readers, reduce the book mode selector spacing and hide secondary vocabulary/tutorial chrome in compact height. Add a persistent Aa text-size menu in both readers, retaining Dynamic Type, selection and audio following.
- Verification: all 237 unit tests and 16 targeted UI scenarios pass across simulator runs on iOS 26.5 / iPhone 17 Pro, including system metadata, clip-relative remote seeking, playback ownership, interruptions, card tap/swipe/undo, both landscape readers, persistent font size and Russian accessibility text. Dynamic Island presentation and third-party media widgets still need a physical-device check.
- DECISIONS.md records the playback ownership and reader preference policies. No project purpose, supported workflow or major boundary changed, so PROJECT.md is unchanged.

## 2026-10-28 — Audit repeated work across interactive screens

- Dictionary translation/meaning/note editing, selection translation, practice audio and boundary sliders no longer read/parse transcripts or resolve aligned audio inside view rendering. Resolve immutable source snapshots on a worker and reuse results until actual audio inputs change, including manual bounds, resource replacement or new timing sidecars. Boundary drags also skip repeated audio-session teardown once the preview is closed. Playback positions and unrelated edits do not invalidate them; cancelled loads cannot install stale controls.
- Build legacy reader documents once per chapter and move both book-reader text/subtitle loads off the UI executor. Cache prepared word-explanation rows across disclosure changes. Isolate library search from dictionary-wide phrase grouping.
- Bound saved-selection regex searches to the original cue and enough subsequent words for cross-cue phrases, retaining whitespace, repeated-phrase and legacy-padding behavior.
- Verification: all 235 unit tests and eight targeted UI scenarios pass on the iOS 26.5 iPhone 17 Pro simulator. A 30,000-cue chapter resolves 100 saved selections in about 10 ms in the synthetic benchmark. Physical-device hang durations have not been measured.
- DECISIONS.md records the execution and invalidation policy. No project purpose, supported workflow or major boundary changed, so PROJECT.md is unchanged.

## 2026-10-28 — Responsive practice translation editing

- Give the practice translation editor its own draft and presentation state. Opening it and typing no longer invalidate the entire practice card, which synchronously resolves phrase audio and loads/decodes source transcripts. Skip audio teardown when no audio is open.
- Preserve Save/Cancel behavior in preview and active rounds; display save failures inside the editor and retain the draft for retry. The editor can expand to a large sheet above the keyboard.
- Verification: 32 learning unit tests and two UI scenarios pass on the iOS 26.5 iPhone 17 Pro simulator, including typing, cancelling, reopening, saving and continuing a round on a card with audio. Physical-device hang durations have not been measured.
- No architectural/product decision or project overview changed.

## 2026-10-28 — Cached activity statistics with manual refresh

- Stop the Activity screen’s 15-second polling and foreground-triggered database reloads. Reuse a persistent derived snapshot across launches and prepared in-memory reports across navigation. With no usable cache, build the initial snapshot once. A long pull down from the top explicitly refreshes the statistics; a timestamp and gesture hint explain when the displayed snapshot was captured.
- Move language collection, database reads, decoding, aggregation, chart buckets, level counts, recent-phrase selection, calendar days and streak preparation off the UI executor. The screen renders bounded ready-to-display values without scanning managed dictionary entries or the activity history on each redraw.
- Preserve the displayed results during refresh and after refresh failures. Coalesce concurrent loads, invalidate prepared reports after a successful explicit refresh and fall back to rebuilding an unavailable/corrupt cache. Canonicalize each source language once during word deduplication instead of once per word.
- Verification: seven cache tests and twelve existing activity-history tests pass; dashboard UI coverage verifies frozen results after practice and updates after a long pull. Other day/week/month, language, empty-state and accessibility scenarios pass, as does the Russian iPad dashboard. A 30,000-event fixture exercises 100 prepared-cache reads without re-aggregation.
- DECISIONS.md records the derived-cache and manual-refresh policy; PROJECT.md describes the supported refresh gesture.

## 2026-10-28 — Center the library Continue action

- Move the Continue button below the featured book’s cover and metadata so it spans the full row, with its label and saved-position caption centered. This removes the offset caused by placing the button inside the right-hand metadata column. An explicit icon/text group also avoids the inherited List label layout shifting the caption.
- No architectural/product decision or project overview changed.

## 2026-10-28 — User activity dashboard

- Added a dark native Activity tab with day/week/month navigation, language selection, new reading words, distinct phrases advanced, phrases reaching level 4, time with books, interactive word charts, a monthly activity calendar, a current streak and recent phrase transitions. iPad uses a two-column layout; Russian/English and accessibility text sizes are supported.
- Word counts reuse earliest recorded reading-form dates, deduplicated by canonical source language. Phrase history starts with this update and records practice, preview and manual level changes atomically; cancelled answers do not count. Each phrase appears once at its highest attained level, alongside the number of promotion events.
- Time records wall time with an open foreground reader or actual background audio, counting simultaneous reading/listening once and excluding suspended intervals. No past time or level history is inferred.
- Independent local activity records survive deleting books/phrases and travel in optional library-backup history. Repeated restores merge stable identities, growing session time and undo tombstones. Old backups remain readable; dictionary-only exports retain their existing scope.
- Verification: 221 unit tests and five Activity UI scenarios passed on iPhone; existing tab-navigation regression passed. Twelve activity unit tests and the Russian day/week/month dashboard UI scenario passed on iPad, including screenshots.
- DECISIONS.md records counting, retention, timing and backup rules; PROJECT.md includes the new supported workflow.

## 2026-10-28 — Book library redesign and local covers

- Replaced library rows with image-led dark layouts, blue primary actions and filters, green reading-progress bars, title search and recent/title sorting. Library, Dictionary and Practice remain available.
- Opening a book now presents its overview, word statistics and ordered chapters/virtual parts. Continue uses the existing saved reader position and explicit-Play recency policy. Chapter rows display completed/in-progress/not-started states, local saved time and inherited book artwork; selecting one resumes its own saved position without marking it read. The in-reader chapter chooser keeps its existing restart behavior.
- Added new/studied unique-word counts, saved-phrase counts and distinct read/unread unique forms from completed text. Phrase bars show the book’s share of saved phrases in the same language; no arbitrary learning target or likes were introduced.
- Import offers six bundled offline covers (about 1.24 MiB combined), custom image upload and automatic case-insensitive `cover` image detection in raw and strict ZIP packages. Covers are validated, bounded to 16 MiB input, downsampled to 1,200 pixels and staged with book resources. Existing records use the supplied books-on-table placeholder.
- Defaulted cover metadata preserves existing SwiftData stores; optional built-in-cover metadata round-trips through library-state backups. Custom cover image bytes remain book assets and are not embedded in state backups.
- Added import/image-boundary and chapter-presentation unit tests, navigation/import/accessibility UI coverage, and Russian/English strings. Updated DECISIONS and PROJECT for the new entry workflow and cover policy.


## 2026-10-27 — Russian and English interface languages

- Use Russian as the default interface language and add an immediate Russian/English switch in Settings. Localize navigation, import, reading, dictionary, practice, backup and configuration screens without changing book text or the fixed Russian translation target.
- Center Quick start text in Dictionary and Practice at both interface languages and large text sizes.
- Order listening-screen toolbar actions as Complete, optional source language, then the rightmost ⋮ menu. Full audio replacement remains in ⋮; move the separate phrase-audio timing update there too, removing its standalone toolbar button.
- Show Translate in Context, Add to Dictionary and Copy as matching icon-and-text actions in the text-selection menu, without grouped dividers. Copy keeps the exact highlighted text.
- Choose Continue Reading from the unfinished book whose Play button was pressed most recently, even when it has no saved progress yet. Existing libraries use their saved-progress order until the first Play tap.
- Show each chapter's audio duration in the chapter picker, including virtual parts of older single-file books.
- Show a horizontal progress bar and numeric percentage for each book in Library and its Continue Reading card, replacing the text progress label.
- Preserve the chosen interface language on this device and in new library-state backups. Older backups without the setting keep the device's current choice.
- DECISIONS.md records the interface-language boundary; PROJECT.md describes the updated workflow.


## 2026-10-27 — Book-based language filter with flags

- Show country flags beside source languages in Dictionary and Practice. Offer only languages present in the library's books; a single-language library shows a fixed labelled flag instead of a picker. When the library is empty, retain access to dictionary entries by their saved language.
- Automatically select an available language when books are added or removed. No new architecture or project boundary changed; DECISIONS.md records the selector's book-based availability rule and PROJECT.md reflects the workflow.
- Verification: targeted language-group unit test and Dictionary/Practice UI checks on iPhone Simulator pass; `git diff --check` passes.


## 2026-10-27 — Six source languages and isolated learning groups

- Support English, French, Spanish, German, Italian and Polish for new books with Russian translations. Import uses one registry independent of Apple pair availability, confirms a separately remembered language, honors supported package metadata and rejects unsupported new packages explicitly.
- Add a shared persisted Dictionary/Practice language dropdown. Lists, level/readiness totals, quick starts, previews, retries, learnt reviews and results stay within the entry's own source language; historical groups remain available. An open round keeps its original language.
- Keep independent unfinished rounds per language with conservative legacy migration and recovery messages. Library backups round-trip all valid checkpoints and typed language preferences, preserve orphan-entry and regional metadata, retain unrelated local rounds, and reject cross-language book matches.
- Group supported regional reading-history tags without rewriting old exports or changing tokenizer/timing versions. Retain same-language knowledge sharing and cross-language isolation. Add Italian function-word handling, neutral mandatory prompt text (v5), source hints for selection tokenization, and explicit rollback for book language changes.
- Align backend/OpenAPI/local tools on the six lowercase source codes. Pin language through idempotency, worker input and new result manifests; reject output-language mismatches and English-only local models for other languages. Quotas, authorization and deployment gate are unchanged.
- Verification: 204 Swift unit tests pass; the new dropdown synchronization/empty-group UI check passes on iPhone 17 Pro Max and iPad Pro 13-inch (M5). Unsigned iOS Release build passes. Backend 15 tests, local aligner 26 tests, worker 3 tests and TypeScript/CDK assertions pass. The full existing UI suite was interrupted during development; only the focused new UI checks are claimed here.
- Real-audio quality benchmarks were not run for any of the six release-matrix languages: no matching fixtures/model weights were present. `docs/ALIGNMENT_BENCHMARKS.md` records provenance, measurement and listening requirements; no deployment or merge occurred.
- DECISIONS.md records language normalization, checkpoint/backup compatibility and alignment contracts; PROJECT.md and affected workflow docs describe the expanded supported workflow. Project purpose and local/cloud boundaries are unchanged.


## 2026-10-27 — Multilingual source implementation plan (documentation only)

- Add `docs/MULTILINGUAL_SOURCE_IMPLEMENTATION_PLAN.md` for six book source languages with Russian translations, shared Dictionary/Practice language filtering, isolated counts and training progress, backup compatibility and local/cloud alignment scope.
- This records the approved implementation scope, not shipped behavior. No implemented architectural decision or current supported workflow changes in this documentation step; DECISIONS.md and PROJECT.md will be updated with the implementation.

## 2026-10-26 — Progressive book import and first-use onboarding

- Add a unified book wizard for text, audio, audio ZIP with optional TXT and complete synchronized packages. Text-only books can be read; audio-only books can be played; unsynchronized books open full text directly.
- Add a vertical book resource menu in library rows and both readers. Missing text/audio can be attached to the same book; replacements preview their consequences. Journaled resource generations, explicit rollback snapshots and startup recovery protect existing files and dictionary data. Compatible synchronization packages verify current text and exact audio bytes.
- Keep independent full-text reading positions. Preserve card text, translations, learning levels and historical studied forms on resource replacement while clearing unsafe old audio links.
- Keep partial books compatible with library-state backups: audio-only identities use recording hashes, and optional reading-anchor/language-lock fields preserve text-only progress without changing older JSON decoding.
- Add contextual first-use tips, a help guide, a tutorial toggle/reset, and an optional original locally narrated example. Existing audio/video with SRT/VTT import remains available.
- Verification: 196 unit tests, iPhone onboarding/import UI checks, iPad wizard/text-only reader checks and unsigned iOS Release build pass. Tutorial dismissal is also verified at the largest accessibility text size.
- DECISIONS.md records resource identity, recovery and tutorial policies; PROJECT.md and README describe the expanded workflow. Project purpose and local/cloud boundaries are unchanged.

## 2026-10-25 — Onboarding implementation plan (documentation only)

- Add `docs/ONBOARDING_IMPLEMENTATION_PLAN.md` with the proposed import wizard, partial-book states, safe resource updates, contextual onboarding, implementation sequence and acceptance checks.
- This is a future implementation plan, not a shipped feature. No architectural/product decision or project overview changed; DECISIONS.md and PROJECT.md remain unchanged. Implementation PRs must record the decisions and supported workflows they actually introduce.

## 2026-10-26 — Portable library state backup

- Move the dictionary transfer toolbar menu to Library as Backup Library / Import Library. Keep older dictionary JSON restore, merge and translation-only imports accessible from Library.
- Export a versioned library JSON backup containing dictionary details and learning levels, studied reading vocabulary, book/chapter/part completion and playback positions, an unfinished training round, settings, both prompts and the bounded detailed-word explanation cache. Book text, audio, subtitles and alignments are excluded; the device-only Keychain API credential and rebuildable indexes are not exported.
- On a new phone, import the same book packages first, then import the library backup. Match by normalized source text plus ordered track IDs/durations, independently of titles and local UUIDs. Restore saved states and reconnect dictionary phrase-audio references to the new local book IDs without moving book files.
- Preview missing, ambiguous or incompatible books and conflicting dictionary identities before restoring. Block application until these are resolved; recheck matches at Apply time. Existing unrelated books, entries and studied words are retained. Model changes save atomically and a failed save restores the previous cache and progress.
- DECISIONS.md records the format and matching policy; PROJECT.md and the backup guide describe the new cross-device workflow. Project purpose and major boundaries are unchanged.

## 2026-10-26 — Preserve chapter progress when leaving the reader

- Ignore progress callbacks after playback closes so Back and reopening resume the current chapter instead of saving the teardown position or stale track snapshots. Apply the same live-player guard to the single-file reader.
- Stop the audiobook position observer when its sleep is cancelled; do not refresh from a closed player. Explicit chapter selection continues to start at zero.
- Add regressions for closed snapshots, cancelled observation, and Back/reopen in both readers, followed by explicit chapter selection. This restores the existing progress contract; no architectural/product decision or supported workflow changed, so DECISIONS.md and PROJECT.md need no update.

## 2026-10-25 — Editable word explanation prompt

- Settings now offers a separate Word explanation prompt editor with save, validation and reset to the default. It applies to detailed explanations opened by tapping a word in Meaning in context.
- Default examples are complete sentences (aiming for 8–20 words) in independent situations, with full translations. They must not quote, paraphrase or reuse the source situation or its characters and events.
- Cache keys include the effective word prompt and its version so changing the prompt avoids previous-prompt results on new requests. Structured output and input safety rules remain mandatory.
- DECISIONS.md records the prompt customization policy. Project purpose, supported workflow and major boundaries are unchanged; PROJECT.md needs no update.

## 2026-10-25 — Dedicated practice settings

- Move phrase cooldown intervals out of general Settings into a dedicated Practice settings screen opened from the Practice tab. General Settings retains contextual translation, API configuration, prompt and diagnostics.
- Preserve saved cooldown values, validation and explicit Save cooldowns behavior; update the round-setup guidance to point to Practice settings.
- Update DECISIONS.md and PROJECT.md for the new settings entry point. Project purpose and major boundaries are unchanged.

## 2026-10-25 — Practice preview text and audio actions

- Replace the practice card’s phrase-actions menu with a larger icon-only translation edit action at the right of the translation, and a vertically centered copy action at the right of the revealed original. Remove translation copying and context copying from practice cards.
- Place playback below the original in a dedicated audio panel. Replace the full-width word/phrase segmented control with a compact fragment menu and simplify the playback-speed control. A visible Edit audio action opens the existing validated boundary editor without a long press. Dictionary audio controls remain unchanged.
- Add UI coverage for text-action alignment, answer hiding, copying, fragment switching and explicit editing of independent word/phrase ranges. DECISIONS.md records the updated practice-card interaction. Project purpose, supported workflows and major boundaries are unchanged; PROJECT.md requires no update.


## 2026-10-25 — Native Glass interface and editorial reading

- Introduce permanent Library, Dictionary and Practice tabs, a featured in-progress book, explicit empty-library import actions and a dedicated practice home with quick start and saved-round access.
- Unify primary and secondary actions, grouped form surfaces and chapter states. Use system Liquid Glass controls and floating playback panels on iOS 26, retaining native iOS 18 fallbacks.
- Give both readers serif typography, Dynamic Type-scaled line/paragraph spacing and a comfortable iPad text measure. Preserve transcript text, UTF-16 selection ranges, paint-only word/cue highlighting and follow-audio behavior.
- Move learning copy/edit commands into a phrase menu; source copying is available only while the original is visible. At accessibility text sizes, preview actions scroll with content instead of covering the phrase.
- Move reading completion into the reading-actions menu, reading vocabulary into a disclosure, and advanced prompt/diagnostic tools into disclosures. Keep explicit confirmations, translation settings, audio-boundary precision and learning rules.
- DECISIONS.md records the visual system and navigation; PROJECT.md updates the supported navigation and reading workflow. Project purpose and major data/service boundaries are unchanged.

## 2026-10-25 — Chapter completion and audio boundary controls

- Natural audiobook track completion marks the finished chapter read through the reading-vocabulary transaction, including the final chapter. Manual selection does not mark chapters read and opens the selected chapter at the beginning with the transcript scrolled to the top.
- Automatic dictionary audio gains 0.5 seconds on either side, clamped to its media track. Stored alignment metadata stays exact; manual overrides play exactly as edited and reset restores padded automatic playback.
- Boundary editing offers two handles on one timeline with 0.1-second adjustments, a phrase-focused scale, whole-track view, preview, and existing numeric shifts in a collapsible section.
- The screen stays awake while an app player is playing; pause, completion, interruption and closing playback restore normal auto-lock when no other player is playing.
- DECISIONS.md records these policies; PROJECT.md updates the supported workflow. Project purpose and major boundaries are unchanged.

## 2026-10-25 — Remove unreachable translation and definition services

- Remove the old Apple word-by-word branch from contextual translation and the unreachable Polish Wiktionary lookup/parser/coordinator. Contextual explanation continues through the existing OpenAI service.
- Remove the SGJP resolver, its exclusive pack builder and the unused 36,861,590-byte compressed bundle resource (about 35 MiB). Reading-vocabulary indexing and contextual lemmas do not use this database; existing installed files are left untouched.
- Preserve the reachable ordinary Apple Translation actions, pending-record recovery, untranslated JSON imports and source-language changes. Preserve SwiftData/JSON word-help and cached definition models, optional lemma fields, historical diagnostics and all backup versions.
- Add legacy JSON/diagnostic compatibility and cloud-context refresh regression checks; extend persistent backup/restore coverage to optional lemma references. DECISIONS.md records the retired/retained boundaries; PROJECT.md and README reflect the current workflow. Project purpose is unchanged.

## 2026-10-25 — Training, audio modes and reading progress

- New/Learnt show their totals without a parenthesized review count; Learning/Practising retain the count without “to repeat”.
- Round results contain only the current round and its preview. Four wrong answers for the same entry in one round block promotion on its eventual correct answer; retries continue until correct. Checkpoints and Undo retain the per-entry counter. Existing wrong-answer demotion remains unchanged.
- Startup translation recovery checks installed languages before creating a session, leaving missing downloads for an explicit retry instead of presenting download UI at launch, and clears idle translation sessions. This addresses a possible source of the reported brief bottom popup; reproduction after a long pause still requires device confirmation.
- Settings can validate the entered or saved API key with a small request to the selected model, showing OK or an error.
- New timed dictionary selections retain separate selected-word and whole-sentence audio ranges. Both modes support manual boundary editing and backup/restore; existing entries are not backfilled. Without word timings, cue boundaries remain the fallback.
- Library and book reader show reading percentage weighted by completed chapters’ audio duration, including legacy parts and whole-book completion.
- DECISIONS.md records the changed behavior; PROJECT.md updates the supported workflow. Project purpose and major boundaries are unchanged.

## 2026-10-22 — Manual phrase audio boundaries

- Long-press the audio button in dictionary or learning cards to edit the start/end boundary, move it earlier/later by fractional seconds, preview, save, or reset to automatic timing.
- Persist per-entry manual ranges, prefer them during playback, preserve them during word-timing updates, and include them in dictionary backup/restore with validation and rollback.
- Record the manual-range decision in DECISIONS.md. Project purpose and major boundaries are unchanged; PROJECT.md now mentions this supported workflow.

## 2026-10-22 — Dictionary review shortcuts and round level changes

- Remove the redundant Translation available label; keep translation errors and pending states. Show ready-to-repeat counts in parentheses after each level total, add a combinable readiness filter, and offer Quick start when eligible phrases have finished cooldown. Counts refresh every 30 seconds.
- Quick start opens the usual preview for up to 10 ready phrases, using the existing lower-level-first selection and new-round checkpoint replacement behavior.
- Completion cards include round phrases and highlight their starting → current level. Starting levels survive round checkpoints and Undo; older checkpoints remain readable without invented starting levels.
- DECISIONS.md records these behaviors; PROJECT.md documents the added review workflow. Project purpose and boundaries are unchanged.

## 2026-10-19 — Follow audio reaches distant cues in one action

- Resolve transcript layout through the active cue and its destination viewport before calculating the scroll limit. Synchronize an underestimated scroll extent with measured text geometry so Follow audio reaches the highlighted passage on the first press.
- Added a 2,000-cue regression with noncontiguous layout and stale content height. Existing same-cue deduplication and manual-scroll behavior remain covered. DECISIONS.md records the geometry rule; project scope and supported workflows are unchanged, so PROJECT.md needs no update.

## 2026-10-19 — Remaining cooldown on phrase cards

- Dictionary list cards and phrase details show the remaining days/hours/minutes until repeat, or Ready to repeat when cooldown expires. Completed level-4 phrases have no countdown.
- Calculate from the persisted level-change date and current global intervals during rendering, rounding remaining minutes up. No ticking timer is used. DECISIONS.md records this display policy; project scope and workflows are unchanged, so PROJECT.md needs no update.

## 2026-10-19 — Play selected words using saved alignment timings

- Add optional word-timing sidecars to book imports and local batch publishing. Reader selections, previews, dictionary cards and learning cards use the first/last selected spoken-word boundaries; missing or zero-duration spoken-word timings fall back to clearly labeled Play context.
- Add Update phrase audio to existing books: validate local audio/text identity, attach timing files without reimporting the book, and refine unambiguous dictionary ranges while preserving source IDs, completion and playback progress. Failed saves restore prior metadata.
- Add a cache-upgrade utility and validate the final saved Lalka conversion: 39 tracks, 258,855 token timings, 9,589 zero-duration tokens; new recognition was unnecessary. Real-data selection tests cover a phrase inside a multiword subtitle cue.
- DECISIONS.md records the optional sidecar and update contract; PROJECT.md includes word-level playback and existing-book updates. See docs/WORD_AUDIO_TIMINGS.md for package details and validation limits.

## 2026-10-19 — Inline copy actions in context translation

- Keep each Copy action on the same row as its explanation, overall translation, original or source sentence, aligned at the right edge. Remove the standalone divider that produced an empty Form row. Apply the same layout to dictionary source context.
- Shared content-row layout only; no product or architectural decision or supported workflow boundary changed. DECISIONS.md and PROJECT.md require no additional changes for this fix.

## 2026-10-19 — Global cooldown settings with explicit save

- Move cooldown interval editing to app Settings with draft fields, validation, Save cooldowns and saved confirmation. Existing global values are preserved; leaving without Save discards edits.
- Exercise setup retains only Ignore words cooldown and a pointer to Settings. DECISIONS.md and PROJECT.md describe the corrected workflow; project purpose and boundaries are unchanged.

## 2026-10-19 — Configurable phrase cooldown

- New practice rounds wait 24/72/96 hours after a transition into level 1/2/3, with editable hour values and an “Ignore words cooldown” checkbox on the start screen. New phrases remain available for first practice.
- Preserve transition dates across backup/restore, failed saves and Undo. Backfill existing missing dates with current time because previous level transitions were not recorded.
- Added cooldown boundary, bypass, migration and rollback/Undo regression coverage. DECISIONS.md records the policy; PROJECT.md describes the updated practice workflow.

## 2026-10-19 — Verify manual transcript swipes with audio paused

- Added a dedicated long-transcript UI regression test for play → pause → successive fast manual swipes, highlight toggling without viewport movement, and reverse scrolling while playback stays paused. The scenario passes with the existing scrolling fix.
- Test fixtures and launch-gated DEBUG telemetry only; no additional Release behavior, architectural decision or project scope changed. DECISIONS.md and PROJECT.md require no further changes.

## 2026-10-19 — Stable reader and chapter-list scrolling

- Paint unknown-word colors, accessibility underlines and active-cue backgrounds through a dedicated layout-manager drawing layer without editing text storage during scrolling. Follow requests are keyed to cue/document/viewport changes rather than fluctuating estimated content height.
- Replace updating chapter/part menus with a native sheet list captured when opened; playback ticks and saved positions cannot rebuild its rows or reset its scroll position. Playback continues while selecting a chapter.
- Added regression checks for viewport stability, redundant follow requests and scrolling to chapter 100 during playback. DECISIONS.md records paint-only decoration and stable chapter snapshots. PROJECT.md notes the chapter chooser; project purpose and network boundaries are unchanged.

## 2026-10-19 — Persistent vocabulary index and library counts

- Library rows show new unique word forms for unread books and total unique forms for explicitly completed books, with loading, updating and retry states. ZIP import and book badges count the same TXT-plus-subtitles corpus.
- Cache parsed source vocabularies and update book counters through a word-to-book index; repeated completion preparation does not tokenize the book again. Reconcile the disposable index with primary knowledge on startup/restore and rebuild it on retry.
- Store new knowledge in bounded SwiftData batches together with completion flags. Preserve old individual records, earliest learned dates, atomic restore and the portable v3 format. No separate competing writer was introduced.
- Cache compact occurrence positions and limit new-word decoration to visible text, preserving native selection, cue backgrounds and following.
- Added index/recovery, representative large-vocabulary, 100-book and library UI checks. DECISIONS.md records the implementation choices and deviations from the initial proposal; PROJECT.md includes the library counter workflow.

## 2026-10-19 — Fill practice rounds across learning levels

- Practice rounds now fill the requested size from level 1, then level 2 and level 3 as needed. For example, a 30-word round with 5 eligible level-1 phrases takes 20 from level 2 and 5 from level 3.
- Updated DECISIONS.md for the round selection rule. Project purpose and supported workflow boundaries are unchanged; PROJECT.md requires no update.

## 2026-10-18 — Compact translation copy and animated swipe answers

- Russian translation and Copy now share one dictionary-detail row; long translations wrap without adding a separate copy row.
- After Check, swipe left for Right (green) and right for Wrong (red). The card follows horizontal dragging and exits in that direction before saving the answer; short or vertical gestures return without answering. Reduce Motion uses color and reduced movement. Undo remains available after the answer saves.
- Updated DECISIONS.md for the reversed swipe mapping. Project purpose, supported workflows and boundaries are unchanged; PROJECT.md requires no update.

## 2026-10-18 — Repository contribution workflow and archived review

- Require new chats to begin from fetched main on a dedicated branch, using a separate worktree when another agent owns the checkout and preserving existing changes.
- Preserve the historical alignment-backend review of de8eed6 with an explicit snapshot disclaimer; its findings are not assertions about current main.
- DECISIONS.md records the contribution workflow. Project purpose, supported product workflows and boundaries are unchanged; PROJECT.md requires no update.

## 2026-10-18 — Studied vocabulary from reading

- Chapters and whole books can be marked read once, with confirmation showing the number of new unique word forms. Whole-book completion includes full TXT and available track subtitles; tracks without subtitles contribute only when the whole book is confirmed.
- Read word forms accumulate locally by language, independently of dictionary cards and learning levels, and survive library deletion. Existing completed chapters migrate without assuming full-book coverage.
- Both import workflows preview unique/new/studied word counts. Both readers show live counts and optional new-word coloring while preserving cue backgrounds and native selection. Source language locks after the first reading completion.
- Dictionary backup v3 includes reading vocabulary, restores it without books and merges it atomically with dictionary records. V1/v2 remain supported; translations-only leaves reading knowledge unchanged. Updated JSON schema and backup instructions.
- Added persistence migration, rollback, Unicode, backup and reader UI checks. DECISIONS.md and PROJECT.md now describe the shipped reading workflow; project purpose and network boundaries are unchanged.

## 2026-10-18 — Level-ordered practice and swipe answers

- Rounds now select only the lowest eligible level, capped by the chosen size; higher levels wait until no eligible lower-level phrases remain. Setup shows the current level and actual round size.
- Revealed practice cards accept right/left swipes for Right/Wrong while preserving vertical scrolling and the answer buttons.
- A three-second Undo restores the last answered card, its level and round counters, including from completion. Save failures retain the answered state; a new answer replaces the previous undo.
- Preview now offers Skip to exclude a word from the current round without changing its level or dictionary record. Integrated current main, including resumable training and inline word explanations; Undo updates the resume checkpoint.
- Updated DECISIONS.md and PROJECT.md for the training workflow; project purpose and major boundaries are unchanged.

## 2026-10-18 — Inline detailed word explanations

- Tap a word in the contextual breakdown to expand a plain-language definition, its meaning in the source sentence, and 1–2 typical source-language phrases with translations. One word is expanded at a time in selection previews, dictionary details and learning cards.
- Details load only on explicit expansion, with local loading/retry states; the short translation stays available. Successful explanations are cached across launches for the exact word occurrence, context, languages, model and prompt version. Cache data is purgeable and is not included in dictionary backups.
- Existing serialized breakdowns are mapped conservatively to source occurrences, including repeated words and UTF-16 offsets. Unsupported legacy text stays readable and can be refreshed through the existing contextual translation action.
- DECISIONS.md records the on-demand request and derived-cache design; PROJECT.md includes the new workflow. Project purpose and cloud-consent boundaries are unchanged.


## 2026-10-18 — Resumable word training and level filters

- Preview reveals the answer immediately only for level 1; levels 2–3 require Check before the three preview actions appear.
- Unfinished rounds are checkpointed after the first Right/Wrong and offered again in the dictionary and learning setup. Closing requires confirmation after answers; swipe dismissal is disabled. Each answer still saves its word level immediately.
- Learning progress rows filter the word list by level, with a reset action and empty state; level 4 shows learnt words in the filtered list.
- Training card copy/edit and copy/audio controls share horizontal rows.
- Updated DECISIONS.md and PROJECT.md for the resumable learning workflow.

## 2026-10-18 — PR integration with main

- Integrated the smoother transcript-following changes from main with dictionary training and phrase-audio improvements, retaining both sets of changelog entries.
- No new architectural/product decision or project overview change; DECISIONS.md and PROJECT.md require no further updates.

## 2026-10-17 — Manual dictionary level selection

- Dictionary detail now lets learners select any level from 1 to 4 in Progress. Changes save immediately and update dictionary counts, learnt grouping and practice eligibility. Failed saves restore the previous level and show an error.
- Recorded the manual level override in DECISIONS.md. Project purpose, supported workflow and major boundaries are unchanged; PROJECT.md requires no further update.


## 2026-10-17 — Pre-learning card preview

- Start round now begins with a revealed preview of every selected phrase, including its translation, audio, source context and contextual meaning. The three bottom actions remain visible while scrolling.
- Start learning keeps a phrase at its current level and queues it for the usual Check/Right/Wrong practice after the preview. Move to next level raises its level once and skips practice this round; Mark as known sets level 4 and skips practice. Each action advances to the next preview card.
- Level changes save before advancing, reject stale/double taps and retain the current card on failure. Missing or ineligible records are skipped. If no phrases are queued, the preview finishes directly; Repeat starts a new preview.
- Updated the learning-round product decision and project workflow overview. Project purpose and major boundaries are unchanged.


## 2026-10-17 — Compact copy controls and dictionary spacing

- All copy buttons now show only an icon, with a temporary checkmark after copying, while retaining descriptive accessibility labels and the copy announcement.
- Moved Copy original beside Play phrase on the source row and removed the speed control from dictionary detail.
- Grouped contextual word explanations and overall translation into one compact Form row so the divider no longer creates an empty full-height row; trimmed display-only surrounding whitespace.
- Updated the dictionary-detail product decision; project purpose, workflows and major boundaries are unchanged, so PROJECT.md requires no further update.


## 2026-10-17 — Complete dictionary metadata backups

- Dictionary JSON v2 now includes contextual breakdown and phrase translation, notes and preferred meaning, legacy word-help/cached definitions, timestamps, translation origin/status, and exact source/track/cue/audio links. Export always includes source context in the UI and checks its own output against importer validation.
- Added Restore backup with a preview of matching records to restore. It restores saved progress and details even when the translation is unchanged, keeps unrelated records and conflicting identities, and rolls back a failed save. Merge and translations-only modes retain their conservative update behavior. Interrupted translations are requeued safely.
- Preserved v1 import compatibility and added ISO 8601 fractional-second support. Added limits and validation for extended data and audio ranges, including overflow-safe UTF-16 context selection validation.
- Audio/media files are not embedded; restored links require the original local book identity and files. Reimporting a book with a new ID does not automatically reconnect audio. Old backups cannot recover fields that were never exported. Added docs/DICTIONARY_BACKUP.md and updated DECISIONS.md and PROJECT.md; project purpose and media-storage boundaries are unchanged.


## 2026-10-17 — Simplified dictionary detail

- Reordered dictionary detail to source phrase with inline playback, Russian translation, then Meaning in context. Source context, progress and other details follow.
- Removed the legacy Word-by-word help UI and contextual-result copy buttons. Existing saved word-help data remains intact.
- Updated DECISIONS.md and PROJECT.md for the simplified detail workflow; project purpose and major boundaries are unchanged.


## 2026-10-17 — Dictionary learning statistics

- Added live dictionary counts for all four learning levels, including zero counts. Level-4 entries now appear only in a separate Learnt phrases section at the end of the list.
- Both sections retain entry details and swipe-to-delete; deletion uses the corresponding section to avoid removing a different entry. Counts include every saved entry, regardless of translation status.
- No architectural/product decision or project overview changed; DECISIONS.md and PROJECT.md require no updates.


## 2026-10-17 — Phrase audio boundaries

- Removed the extra 0.75-second tail from phrase capture in both readers. Play phrase now uses only the selected subtitle cues.
- Existing saved phrases also drop recognizable legacy padding when the local transcript and selection match; ambiguous or custom ranges remain unchanged. Timing remains limited to subtitle cue precision, without estimating word timings.
- No architectural/product decision or project overview changed; DECISIONS.md and PROJECT.md require no updates.


## 2026-10-17 — Training start button layout

- Made Start round a full-width, large button without the surrounding Form row background or inset, and moved the empty-state hint to the section footer.
- No architectural/product decision or project overview changed; DECISIONS.md and PROJECT.md require no updates.


## 2026-10-17 — Contextual translations in training

- After Check, training cards show saved contextual word explanations and a separate overall phrase translation. Use this as translation replaces the saved phrase translation only on explicit selection.
- Missing analysis can be generated using the existing contextual translation service, with progress, errors and cancellation when leaving a card. Entries without source context use the phrase itself without inventing surrounding text.
- This extends the existing training workflow; no architectural decision, project purpose or major boundary changed. DECISIONS.md and PROJECT.md require no further changes.

## 2026-10-16 — Smoother transcript following

- Keep the active cue stationary inside a 35–60% reading zone; smoothly move its first visual line to 40% when it leaves that zone. Respect Reduce Motion and stop following on manual scrolling or selection.
- Recalculate after text layout and content geometry changes, and explicitly resume after playback and seek actions in both readers.
- Added reading-zone, layout-change, repeated-layout, selection and explicit-resume regression coverage.
- Updated the follow behavior decision. Project purpose, supported workflows and major boundaries are unchanged.

## 2026-10-16 — EPUB preparation for audiobook subtitles

- Added a local EPUB extraction step that follows spine order, preserves inline text and punctuation, removes semantic notes/navigation, and writes UTF-8 sections plus a source/skip index. The explicit Wolne Lektury profile also removes fundraising, annotation and publishing pages.
- Prepared the supplied 39-part Lalka book from EPUB: 34,399 cues per format over 32 hours, validated with the app parser/manifest validator and retained as local review-required artifacts. Added a conversion report documenting source mapping, fixes and remaining timing limitations.
- Documented chapter-to-audio matching and the existing per-track alignment/package workflow. EPUB extraction does not infer audio boundaries or change the iOS import formats.
- Shortened guided alignment targets from 60 to 20 seconds after longer windows produced local timing drift in the Lalka recordings. Bumped the alignment core version so cached output from the previous behavior is not silently reused.
- Added extraction and guided-window regression tests and updated the architecture and project overview for EPUB as a supported local preparation source. Project purpose is unchanged.

## 2026-10-15 — Background audio, contextual dictionary capture and track controls

- Enabled the iOS background audio mode alongside the existing spoken-audio playback session so audio can continue when the screen locks. Physical-device lock-screen playback and automatic track transitions still require a device smoke test.
- Changed the book slider, elapsed/total time and 10-second seeks to use the current track. Legacy virtual-part timers now also show part-relative time.
- Added Add to Dictionary to the contextual translation popup. Both reader capture actions use the same contextual result; direct capture obtains it before saving, and reopening the same last selection reuses its successful result. Saved entries contain the phrase, primary translation, word breakdown, context and exact audio source. Duplicate taps and dismissed requests cannot insert extra entries.
- Versioned the production prompt and strict response schema to return source word, lemma and concise comma-separated meanings, with blank lines between words and the overall contextual phrase translation below. Removed requests for grammatical commentary. Existing custom prompts remain, with the concise output contract enforced after them.
- Contextual word breakdowns now omit common conjunctions, prepositions and connecting words (including Polish ale, i, z, przed/pred and na), using a language-specific list with case/punctuation normalization. Short content words stay visible; function-word-only selections still translate and save normally. The v4 request carries the exact filtered word list while the overall translation retains the full phrase. This refines the existing workflow; project purpose and major boundaries are unchanged.
- Added model-error alerts with OK, bounded persistent diagnostic metadata and Export logs in Settings, the selection popup and dictionary details. Logs exclude credentials, prompt/input text and response bodies. Failed dictionary context saves restore the previous result and surface an error.
- Added distinct orange, blue, purple and green progress badges while retaining level numbers and names.
- Updated DECISIONS.md and PROJECT.md for the new capture workflow, diagnostic export and background playback. Project purpose is unchanged.

## 2026-09-24 — Direct OpenAI contextual translation with user key

- Replaced both contextual Apple Translation routes with one bounded application-wide service that
  calls the OpenAI Responses API and requires strict structured output for the selected phrase and
  its contextual explanation. Word-by-word and ordinary automatic translation remain on Apple
  Translation.
- Added an explicit cloud opt-in, model selection, and user-provided OpenAI API key management. The
  key is stored only in the device Keychain and is sent directly to OpenAI; it is not bundled with
  the app, written to `UserDefaults`, or added to the repository. Usage is billed to its owner.
- Preserved ephemeral reader previews and separately persisted dictionary results, stale-response
  guards, the last successful result on failure, and explicit acceptance before replacing a saved
  translation. Added request/error/decoding tests and documented the BYOK boundary.
- Context explanation now returns and validates one concise contextual grammar/meaning line for
  every selected word, preserves source order and duplicates, and shows the natural translation of
  the complete phrase after the word breakdown.
- Added a prompt editor backed by an optional `UserDefaults` override, with the production default
  kept in code and an explicit reset action. The application still appends its non-editable strict
  output and untrusted-context safety contract to every request.
- Recorded the direct-BYOK cloud architecture in `DECISIONS.md` and updated `PROJECT.md` because
  contextual translation is no longer local-only. No relay or project-owned API credential is part
  of this release.

## 2026-09-23 — Multi-track audiobook import and playback

- Added previewed local ZIP and strict `.book.zip` import for 1–100 audio tracks, generated stable track identities, sequential playback, cross-track global seeking, per-track resume positions, and full-book untimed reading.
- Added manifest-linked per-track SRT/WebVTT reading and dictionary audio references keyed by `(item ID, track ID)` so equal local cue times on different tracks resolve to the correct file. Plain full-text selections remain deliberately untimed.
- Added streamed archive limits and CRC/path/collision checks, staging journals, save rollback, startup recovery, and reversible library deletion so filesystem changes do not masquerade as database transactions.
- Extended the shared selection preview, phrase-audio resolver, playback intent/rate controller, transcript follow behavior, dictionary detail, and learning round UI with track-aware behavior while preserving their existing lifecycle and accessibility contracts.
- Added the strict v1 book JSON schema and a sequential multi-track alignment CLI with full preflight, reports, fail-closed publishing, and fingerprint-checked single-track reruns.
- Recorded the track-local timeline, immutable identity, untimed TXT, legacy adapter, migration, import transaction, and batch publishing decisions. Updated the project overview because multi-track ZIP import and batch alignment are now supported workflows.

## 2026-09-23 — Generated Xcode project troubleshooting

- Documented the stale local Xcode project that omitted `SelectionTranslationPreview.swift`, and its repair through `bash scripts/bootstrap.sh`.
- Added a [prevention and recovery guide](../docs/PREVENTING_GENERATED_PROJECT_DRIFT.md), linked from the README, covering regeneration triggers, build/test commands, CI generation, and safe handling of merge conflicts and concurrent edits.
- The local unsigned Debug simulator build succeeded after regeneration; no Swift source change was required. This guide documents the existing XcodeGen workflow, with no new automated enforcement. Architectural/product decisions and the project overview in `DECISIONS.md` and `PROJECT.md` are unchanged.

## 2026-09-22 — Learning and playback UX

- Changed Translate in Context in the reader to an ephemeral preview that translates the phrase and its containing sentence without creating or modifying a dictionary entry.
- Added reliable selection-triggered pause, TextKit-based transcript centering, explicit Follow recovery, and session-local 0.5×–2× playback speed controls.
- Added 5, 10, 20 and all-available learning rounds with a fixed unique starting set, retry-at-end behavior for wrong answers, save-before-advance progress, duplicate-event protection, and explicit skipped-entry accounting.
- Added phrase audio and exact-copy controls across preview, dictionary detail and learning, while keeping original/audio/context hidden until a learning answer is checked.
- Round completion now lists all valid level-4 Russian phrases from current stored data, including phrases learned before the round.
- Updated `PROJECT.md` for the expanded supported learning workflow. Project purpose and system boundaries are unchanged; no persistent preference, transfer-schema, backend or multi-track decision was introduced.

## 2026-09-22 — Cloud alignment backend implementation

- Added an undeployed AWS backend implementation for one audio + matching TXT alignment job: a
  capability-authorized HTTP API, version-pinned multipart uploads, DynamoDB state/idempotency and
  atomic global admission counters, a versioned Standard Step Functions workflow, one CPU Fargate
  worker per accepted start, manifest-gated publication, cancellation, reconciliation and cleanup.
- Preserved public testing without sign-in and the 60-minute hard duration ceiling. Job IDs do not
  grant access; each create request uses a fresh 32-byte client capability, and the service stores
  only its SHA-256 digest. Existing local import and local alignment behavior is unchanged.
- Added an OpenAPI contract, hash-locked Linux/x86_64 CPU worker dependencies, immutable image/model
  build inputs, CDK infrastructure assertions, backend race/validation tests and CI coverage.
- Recorded the benchmark and deployment gate in `docs/ALIGNMENT_BENCHMARKS.md`. No AWS resources were
  deployed, no production pricing or 60-minute benchmark is claimed, and the iOS remote upload/UI
  client remains future implementation work.
- Recorded the temporary-cloud-processing architecture in `DECISIONS.md` and updated `PROJECT.md`
  because the repository now contains an optional backend boundary even though the shipped app
  remains local-first and has no configured service endpoint.

## 2026-09-22 — Reviewed implementation proposals

- Reviewed the AWS alignment, learning UX and multi-track audiobook plans against the current code, resolved contradictory requirements, and added explicit state, timing, persistence, migration and acceptance contracts for implementation.
- Recorded the user-confirmed cloud testing scope: public job creation without sign-in, private per-job access, and recordings up to 60 minutes. Production authentication and broader hardening are deferred to the general [future improvements backlog](../docs/FUTURE_IMPROVEMENTS.md).
- These are implementation proposals, not shipped capabilities. Current architectural decisions and the project overview in `DECISIONS.md` and `PROJECT.md` are unchanged; future implementation PRs must update them when behavior changes.

Entries are ordered oldest to newest and summarize the project history recovered from the repository and Codex task history.

- Fixed Force Translation in the dictionary entry screen so it runs immediately in that screen, shows a translating state instead of “queued,” and explains that the operation may take a moment. No architectural or project-overview decision changed.

## 2026-09-15 — Native iOS foundation

- Created the SwiftUI iPhone/iPad app, XcodeGen specification, unit/UI test targets, simulator CI, and signed publishing workflows.
- Added initial setup, release, signing, and troubleshooting documentation.

## 2026-09-15 — Media transcript library

- Added local audio/video import, SwiftData library models, resume positions, transcript parsing, synchronized playback, native text selection, and phrase dictionary capture.
- Added tests for parsing, timing boundaries, Unicode ranges, backward seeking, overlap policy, dictionary persistence, and core UI flows.

## 2026-09-15 — Subtitle alignment utility

- Added the standalone TXT + audio aligner with SRT/WebVTT export, chapter offsets, guided alignment, validation diagnostics, and review output for untimed words.
- Documented the Polish sample conversion experiments and limitations.

## 2026-09-16 — Virtual learning parts and dictionary roadmap

- Added the virtual learning-parts direction so practice content can be organized without duplicating media.
- Documented translation options, Russian as the initial target, portable dictionary JSON, translation-only imports, conflict handling, and learning-session design.

## 2026-09-16 — Transcript seek synchronization

- Added seek-generation guarding so stale AVPlayer callbacks cannot overwrite a newer requested position.
- Resynchronized the displayed position after the active seek completes; the full local suite passed with 7 unit tests and 2 UI tests in the recorded task.

## 2026-09-16 — Knowledgebase governance

- Added this knowledgebase and `AGENTS.md` rule requiring every completed PR to update project knowledge.

## 2026-09-16 — Translation queue reliability

- Invalidated same-language Apple Translation configurations between dictionary jobs so every queued phrase starts instead of only the first phrase translating.
- Added a Force Translation action to dictionary entry details, with confirmation before replacing an existing translation.
- No architectural/product decision or project-overview change was required.

## 2026-09-16 — Dictionary context visibility

- Added saved source context to dictionary entry details and to the revealed side of learning cards.
- No architectural/product decision or project-overview change was required.

## 2026-09-16 — Contextual translation and sentence help

- Added a Translate in Context transcript action that compares the selected expression with a translation of its containing sentence and highlights the saved selection.
- Added on-demand word-by-word sentence help, with common grammar words hidden by default but available through a reveal toggle.
- Added editable preferred-meaning and personal-note fields, while preserving existing manual or imported translations until the learner explicitly accepts a contextual candidate.
- Translation configurations prefer Apple's high-fidelity strategy on iOS 26.4 and later while retaining the iOS 18-compatible path on earlier systems.
- Moved CI and publishing to the macOS 26 runner with Xcode 26.6 so the iOS 26 Translation APIs compile and are tested consistently.
- Recorded the contextual translation architecture and updated the supported dictionary workflow; no broader project-purpose or boundary change was required.

## 2026-09-16 — Sentence-based source context

- Limited captured dictionary context to the selected sentence plus the preceding and following sentences.
- Trimmed the adjacent sentences to 15 words each, preserving the selected phrase and reducing oversized context cards.
- No architectural/product decision or project-overview change was required.

## 2026-09-17 — Polish Wiktionary definitions

- Added explicit per-word Polish Wiktionary lookup to word-by-word help, with numbered Polish definitions, usage labels, matching examples, source attribution, retry, and refresh states.
- Cached successful Wiktionary results inside saved word-help data so previously viewed definitions remain available offline and survive translation refreshes.
- Added fixture-backed coverage for multilingual article isolation, definition/example parsing, errors, and Polish query encoding.
- Recorded Wiktionary as the first third-party runtime data source and updated the project boundary accordingly; the app still has no backend or analytics.

## 2026-09-17 — Listening and vocabulary market research

- Added [market research](../docs/LANGUAGE_LEARNING_MARKET_RESEARCH.md) comparing LingQ with nine alternatives/workflows, linking user feedback, and prioritizing listening and vocabulary-retention features.
- Mapped proposed features to the current Swift implementation with estimated engineering effort, illustrative budgets, operating-cost assumptions, and a phased validation plan.
- Recommendations are not adopted product or architectural decisions. No project-overview or supported-workflow change was made.
- Перевёл отчёт исследования на русский язык, сохранив структуру, источники, оценки и технические рекомендации.

## 2026-09-17 — Audio playback for saved phrases

- Saved dictionary entries now retain the absolute transcript cue start/end when created from timed media.
- Added a Play/Pause control to dictionary-entry details that reuses the local source media and plays only the saved phrase range.
- Entries imported from JSON, created from untimed text, or whose source media is unavailable continue to work without audio and show an unavailable state.
- Added coverage for source-index preservation and persisted audio ranges. No new architectural decision or project-overview change was required.
- Extended phrase audio to include every subtitle cue touched by a selection and a bounded 0.75-second tail, preventing natural speech from being cut at the first cue boundary.
- Increased the document-picker UI test wait for slower CI simulator launches; no product or architectural decision changed.

## 2026-09-17 — Offline Polish form resolution

- Added a bundled SGJP morphology index containing 4,934,967 Polish surface forms and 5,252,824 unique form-to-lemma pairs.
- Polish Wiktionary lookup now resolves missing inflected forms locally, including `został → zostać`, before requesting the lemma article.
- Added an explicit lemma chooser for ambiguous forms, first-use database installation, SGJP attribution, and a reproducible pack builder.
- Recorded the bundled language-pack architecture and updated the supported dictionary workflow and repository map.

## 2026-09-18 — Reading and review refinements

- Fixed transcript content and highlight synchronization when switching between virtual audiobook parts.
- Expanded partial transcript selections to complete word boundaries before saving or translating them, while preserving the exact selected range in context.
- Added compact phrase translations to dictionary rows.
- Learning cards now highlight the saved phrase in source context and allow the Russian translation to be edited directly.
- Wrong learning answers now return to the end of the current queue, and the round continues until every queued entry is answered correctly.
- Polish Definition failures are now written to the iOS unified log and to a bounded, protected local diagnostic file; the existing dictionary export includes that log and environment metadata for support.
- Recorded the local diagnostic-retention/export decision; no project-overview change was required.
