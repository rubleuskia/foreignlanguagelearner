# AWS alignment backend — code review report

> Historical review of commit `de8eed6`, preserved from local work. Findings and verification below describe that snapshot, not current main. Revalidate before treating them as open defects. This document does not authorize deployment.

## Assignment

Review and harden the undeployed backend that runs `tools/subtitle-aligner` on AWS. Work from the current `main` branch and keep the local-first iOS behavior unchanged. Do not deploy AWS resources or weaken the documented security boundary.

Reviewed commit: `de8eed6` (2026-09-28). Scope: `backend/alignment/`, `infra/alignment/`, `tools/subtitle-aligner/worker/`, related tests and deployment documentation.

## Verification at the reviewed snapshot

- `python3 -m unittest discover -s backend/alignment -p 'test_*.py' -v`: **13/13 passed**.
- `python3 -m unittest discover -s tools/subtitle-aligner/worker -p 'test_*.py' -v`: **fails during test discovery** with `ModuleNotFoundError: No module named 'worker.worker'`.
- `npm test` in `infra/alignment`: **cannot run in this checkout** because `tsc` is not installed (`sh: tsc: command not found`). After dependencies are installed, rerun the complete CDK test suite.
- No AWS integration, container-build, Step Functions execution, or end-to-end upload test was available in the review environment.

## Findings

### P1 — Worker tests are not runnable from the repository

Evidence: `tools/subtitle-aligner/worker/test_worker.py:9` imports `worker.worker`, while discovery from `tools/subtitle-aligner/worker` resolves `worker` to the local `worker.py` module rather than the package. The current command fails before executing any worker test.

Why it matters: the worker is the compute boundary and currently has no executable regression suite. A change to S3 version handling, cancellation, probing, or manifest publication can pass CI without testing the worker.

Required fix:

1. Choose one supported invocation and make it work from repository root and CI (prefer `python -m unittest discover -s tools/subtitle-aligner/worker -p 'test_*.py'` or a documented equivalent).
2. Avoid the `worker.py` module/package name collision, or change imports to a stable package/module path.
3. Add the command to CI and prove that all worker tests execute, not merely that discovery succeeds.

Acceptance: a clean checkout with the documented Python dependencies runs the worker suite with at least the existing tests passing.

### P1 — No end-to-end contract test covers the Step Functions/Fargate result path

The implementation depends on a multi-service contract: the worker writes versioned manifest/outcome objects and DynamoDB pointers; `finalizer.py` reads those pointers; the CDK state machine passes ECS task output/errors. Existing unit tests cover isolated pieces but do not render the state machine and feed representative `RunTask` success, non-zero exit, timeout, duplicate-claim, cancellation, and missing-outcome cases through the finalizer.

Why it matters: the backend can synthesize successfully while a field-path mismatch leaves jobs stuck in `starting`/`running` or converts real failures into generic failures.

Required fix:

- Add a contract test using the synthesized state machine JSON and representative ECS/worker events.
- Assert that success publishes only a valid manifest, failure and timeout reach the same finalizer, cancellation wins over late success, and missing outcome/manifest is terminal and retryable by reconciliation.
- Assert that the worker's DynamoDB pointer is sufficient even when ECS stdout is unavailable.

Acceptance: the test fails if the Step Functions payload shape or finalizer event shape changes incompatibly.

### P1 — Upload completion trusts `HeadObject` for the current TXT object instead of pinning the intended upload version

Evidence: `backend/alignment/service.py:145-176`. The TXT presigned PUT targets a stable key. A client or replayed URL can replace that key before `complete-upload`; completion then calls `head(job["text_key"])` without a version ID and pins whichever version is current. The declared checksum is sent in the signed URL, but the completion path does not verify the returned object's checksum against the declared SHA-256.

Why it matters: the worker later verifies the pinned bytes, so this may become a late `CHECKSUM_MISMATCH`, but the API can record attacker/replayed content as the job's immutable input and the behavior is inconsistent with the documented checksum contract.

Required fix:

- After the PUT, obtain and persist the exact object version that was uploaded, or verify the current object's returned SHA-256 checksum against `expected_text_sha256` before pinning it.
- Preserve the version ID and checksum atomically with the upload-complete transition.
- Add a test for a wrong-checksum TXT object and a test for a newer replacement version.

Acceptance: `upload_complete` is never recorded for bytes whose size and full-file SHA-256 differ from the create declaration.

### P2 — Reconciler state transitions need explicit regression coverage

Evidence: `backend/alignment/reconciler.py:38-75`. The reconciler reloads a job after finalization and then continues through cleanup/expiry logic in the same pass. The current status guards appear to prevent a second finalization, but this race-sensitive behavior is implicit and has no tests covering a completion observed by the reconciler at the same time as cancellation or cleanup.

Required fix:

- Add tests for success, failure, timeout, cancellation, and a terminal job with pending cleanup.
- Assert that terminal jobs are never stopped/finalized a second time and counters/cleanup guards remain exactly-once.

### P2 — Worker cancellation is reported as infrastructure failure

Evidence: `tools/subtitle-aligner/worker/worker.py:102-105, 232-254`. SIGTERM calls `cancel()`, which raises `WorkerFailure("INFRASTRUCTURE_FAILURE")`; the worker then tries to upload an `outcome.json` and exits with code 1. The control plane eventually maps cancellation using task/execution state, but a task-level termination can race with outcome publication and obscure the cancellation reason.

Required fix:

- Define an explicit cancellation outcome/code or document why cancellation is intentionally represented as infrastructure failure.
- Test SIGTERM during download/inference and verify the final state is `cancelled`, no result is published, and admission is released once.
- Ensure the watchdog timeout remains distinguishable from external cancellation.

### P2 — Backend worker test coverage does not exercise the actual aligner invocation

The current worker tests cover hashing, probing, and duplicate claim only. They do not test download version IDs, checksum mismatch, output-size rejection, cue validation, private diagnostic handling, manifest input pinning, or outcome publication.

Required fix: add focused tests with fake S3/repository adapters for those paths. Do not require AWS credentials. Include at least one successful fake `align.run` path and one failure path with user text in diagnostics; assert that the text is not printed to stdout/stderr.

### P2 — Deployment gate is documented but not mechanically enforced

`docs/ALIGNMENT_BENCHMARKS.md` requires a benchmark before deployment, but the CDK stack only requires an image digest and repository name. There is no checked-in benchmark result, CI gate, or deploy script that refuses an unqualified image/profile/resource combination.

Required fix: add a machine-readable benchmark artifact/schema and a pre-deploy validation command. It must verify the selected 60-minute input envelope, memory/disk headroom, output limits, and cost assumptions before allowing a deployment command. Keep the gate fail-closed when measurements are absent.

### P3 — CI/dependency instructions are incomplete for infrastructure validation

The repository contains `infra/alignment/package-lock.json`, but the review environment cannot run `npm test` because dependencies were not installed and no repository-level instruction/CI job was found that installs and runs the CDK tests. This is partly environment setup, not necessarily a production defect, but it leaves the deployment artifact unverified.

Required fix: make the CI command explicit (`npm ci` then `npm test` in `infra/alignment`) and add it to the workflow if absent. Do not commit generated dependency directories.

## Suggested execution order for the junior model

1. Repair worker test packaging/imports and CI commands; run all Python and CDK tests.
2. Add the upload checksum/version tests and fix the completion path.
3. Add reconciler state-transition tests and simplify the post-finalization flow.
4. Add worker adapter tests and the Step Functions/finalizer contract test.
5. Implement the fail-closed benchmark gate.
6. Update `knowledgebase/CHANGELOG.md` and `knowledgebase/DECISIONS.md` for any behavior or architectural change. Update `knowledgebase/PROJECT.md` only if the supported workflow or system boundary changes.

## Definition of done

- No P1 finding remains open.
- Python backend and worker tests run from a clean checkout using documented commands.
- CDK TypeScript tests and synthesis run after `npm ci`.
- Uploads are pinned only after size and declared full-file checksum validation.
- Reconciliation and cancellation are idempotent under retries and races.
- No raw user text, paths, tokens, or SDK exception details enter ordinary logs/API errors.
- No AWS deployment is performed as part of this task.
