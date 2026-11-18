# Exam domain API and durable storage

`backend.exams.service.Service(storage_root, now=time.time)` is the persistent domain service. `storage_root` must be an explicitly selected durable directory. It contains `exams.sqlite3`, immutable `packages/{exam_id}/{revision}/` directories and prepared `imports/{import_id}/` directories. SQLite uses WAL, foreign keys, immediate write transactions and FULL synchronous writes. There is no in-memory repository or implicit temporary-disk fallback.

The local HTTP server and deployed runtime are separate adapters. The presence of this domain implementation does not establish a production cloud filesystem, deployment or live AI verification. `backend.exams.runtime` requires explicit `EXAM_STORAGE_ROOT`; an unconfigured runtime returns `EXAMS_NOT_CONFIGURED`.

## Public Python methods

| Method | Result / responsibility |
| --- | --- |
| `dry_run(owner, package_dir)` | Copies and verifies a complete source-linked package into persistent staging; returns `import_id`, `manifest_digest`, `content_digest`, exam/revision, structure summary, action, errors and warnings. Does not publish the catalog. |
| `commit(owner, import_id, transaction_id, expected_manifest_digest)` | Revalidates prepared bytes, publishes a complete immutable revision and updates its catalog pointer in one database transaction. Replays of the same transaction return the same result. |
| `catalog()` | `{schema_version: "1.1", exams: [...]}` containing one published revision per exam. Called behind the authenticated API adapter. |
| `student_package(exam_id, revision=None)` | `{schema_version: "1.1", exam: <student projection>, audio: <student projection>}`. Omitted revision resolves the catalog pointer; explicit old revisions remain readable. |
| `resolve_asset(exam_id, revision, source_id)` | Trusted transport-only `{path: Path, bytes, sha256, media_type}` after integrity verification. Only `paper` and `audio` are accessible. Never JSON-serialize the local path to a student. |
| `download_metadata(exam_id, revision, source_id)` | `{download_path, bytes, sha256, media_type}`. The relative path points to the same authenticated origin's `/sources/{source_id}/content` endpoint. |
| `create_attempt(owner, payload)` | Creates or returns an idempotent owner-scoped attempt pinned to an immutable revision. |
| `get_attempt(owner, attempt_id)` | Snapshot, including server time and any server-side deadline transition. Other owners receive a not-found error. |
| `list_attempts(owner)` | `{attempts: [snapshot, ...]}` for this owner only. |
| `update_attempt(owner, attempt_id, payload)` | Optimistic, idempotent patch of responses/progress. Never accepts edits to a submitted section. |
| `submit_attempt(owner, attempt_id, payload)` | Submits one selected section or all selected sections and computes deterministic scores from the server's keys. AI tasks remain pending until a separate result is recorded. |
| `assessment_context(owner, attempt_id, task_id)` | Private execution context `{exam, task, responses, attempt}`. Only grammar V/VI in an already submitted selected section are allowed. Never expose this full context as the active student package. |
| `assessment_input(owner, attempt_id, task_id, feedback_language="pl")` | Authorized after-submit `{request, contract}` for the personal-key route, prepared with the shared source-bound contract. Does not run AI. |
| `record_assessment(owner, attempt_id, task_id, result, provenance, *, server_verified=False)` | Validates and stores a task-level score/rationale, revision and contract fingerprint, then refreshes the aggregate result. Default origin is `client_personal_key`; only trusted server code can set `server_verified=True`. |
| `handle(route, owner, payload=None, params=None, query=None)` | Convenience wrapper over `backend.exams.api.handle(service, route, owner, body, params, query)`. Returns domain values; transport chooses HTTP response handling. |

Owner identity is supplied by the authenticated transport, not by the request body. `ExamError` inherits `backend.cloud.errors.CloudError` and has `code`, `status`, and optional `details`. Import methods require operator/admin authorization at the transport boundary; a normal subscription route must not expose filesystem import to students merely because they have an owner ID.

## Import and revision contract

The runtime schema is `backend/exams/exam.schema.json`, copied from the reviewed import schema 1.1. Import never trusts a replacement schema supplied inside a package. The package must contain `exam.json`, original source files, and `artifact-manifest.json`; a listening package also needs valid `audio.json`.

All listed artifacts must exist with the exact declared size/hash and original-source provenance. Unlisted files, symlinks, absolute/escaping paths, changed originals, invalid PDF page references, unknown item/option/gap IDs, invalid score totals, source-inconsistent AI metadata and out-of-range/overlapping audio intervals are rejected. Structural validation is not a new OCR, physical audio-duration or editorial-content review; those quality results remain source-linked artifacts from digitization.

The content revision is recomputed from canonical exam JSON without its revision field plus canonical audio JSON. The transport manifest digest is separate. Repacking documentation without changing canonical content can create a new transport digest and remains a content no-op. Republishing an old unchanged revision does not downgrade a newer catalog pointer. An invalid or partially prepared revision is never visible in the catalog.

CLI, from the repository root:

```sh
python -m backend.exams.cli --storage-root /absolute/durable/path --owner operator \
  dry-run /absolute/exam/package
python -m backend.exams.cli --storage-root /absolute/durable/path --owner operator \
  commit --import-id IMPORT_UUID --transaction-id TRANSACTION_UUID --manifest-digest PREPARED_DIGEST
python -m backend.exams.cli --storage-root /absolute/durable/path --owner operator catalog
```

The exact import HTTP bodies are `{package_dir: "/absolute/path"}` for dry-run and `{transaction_id, expected_manifest_digest}` for commit. The local loopback server accepts these administrative operations behind its explicit bearer token; this is not a remote-upload implementation.

## Student delivery

Student projections use explicit allowed fields. They preserve all five source sections, but `interactive_section_ids` contains only available listening/reading/grammar modules. Presentation data, printed worked examples and original paper/audio metadata remain available. Answer keys, grading objects, rubrics, AI assessment metadata, raw ASR/evidence, source-review attachments and the original `keys` PDF are excluded.

Audio delivery contains the original audio SHA/duration, review status and task/occurrence IDs, original-relative millisecond ranges and primary/repeat roles. The full original MP3 remains the exam-mode audio source. There is no public key-PDF download route; direct source access is restricted to `paper` and `audio` even after guessing another source ID.

Routes implemented by the domain adapter:

```text
GET  /v1/exams
GET  /v1/exams/{id}
GET  /v1/exams/{id}/revisions/{revision}
GET  /v1/exams/{id}/revisions/{revision}/sources/{source_id}/download
POST /v1/exam-imports/dry-run
POST /v1/exam-imports/{id}/commit
GET  /v1/exam-attempts
POST /v1/exam-attempts
GET  /v1/exam-attempts/{id}
PUT  /v1/exam-attempts/{id}
POST /v1/exam-attempts/{id}/submit
GET  /v1/exam-attempts/{id}/assessment/{task_id}
POST /v1/exam-attempts/{id}/assessment/{task_id}
```

The authenticated binary `GET .../sources/{source_id}/content` is handled by the HTTP transport using `resolve_asset`, with byte ranges. It is intentionally not a JSON response from the domain adapter.

## Attempts and two-device synchronization

Create body:

```json
{
  "attempt_id": "6de8dba3-38ba-47ef-9ffa-d93730c67c55",
  "exam_id": "pl-b1-2024-06-adults",
  "revision": "64 lowercase hexadecimal characters",
  "mode": "exam",
  "device_id": "device-a",
  "section_ids": ["reading"]
}
```

Mode is `exam` or `training` and cannot change within an attempt. `section_ids` is a nonempty subset of the package's interactive sections; omitting it selects all interactive sections. UUIDs normalize to lowercase. Snapshot identity is `id`, not the create body's `attempt_id`.

Snapshots include owner_id, exam_id/revision, mode, device_id/active_device_id, selected section_ids, version, state, responses, progress, submitted_section_ids, section_submission_reasons, section_started_at, section_deadlines, assessments and result. Server-owned timestamps are UTC ISO8601 strings without fractional seconds: created_at, updated_at, started_at and server_time. Progress is `{section_id, task_id, audio_cursor_ms, elapsed_ms: {section_id: int}}`.

PUT body requires `base_version`, unique `change_id`, and `device_id`; optional fields are responses, progress, state and takeover. Responses are a patch, not a replacement; each value is a string or a unique allowed-choice array according to the source item. State can be `in_progress` or `interrupted`. Progress task IDs must belong to the selected section and audio cursor must stay inside the original audio duration.

A repeated change_id with the identical body never applies twice and returns the current snapshot. Reusing it for another body is a conflict. A stale base_version returns 409 `EXAM_ATTEMPT_CONFLICT` with `details.current_version` and the current snapshot. The client must retain its local draft and resolve the conflict instead of silently changing its base version and overwriting the server.

An update or submission from a different active device returns 409 `EXAM_DEVICE_CONFLICT`. After explicit user confirmation it can send `takeover: true`, the latest base_version, a new change_id and its device_id. Ownership remains unchanged, while the active device is transferred. This prevents automatic merging of audio cursors or accidentally skipping unheard audio.

Submit uses the same base_version/change_id/device_id fields, plus optional section_id and takeover. Without section_id it submits all selected sections. Responses to submitted sections are immutable. Deterministic server scoring covers exact answers, sets and unique numeric membership with the official partial-credit rules. `result.sections[].items[]` always includes both item_id and task_id, so clients never parse stable IDs to infer their parent task.

## Deadlines and interruption policy

In exam mode, starting reading/grammar creates a server deadline from the source time limit. The first selected section starts at creation; switching `progress.section_id` starts another section once and does not pause previously started deadlines. Training has no deadline. `elapsed_ms` is progress data and cannot override server time.

GET, PUT and submit apply overdue deadline transitions before returning or accepting a change. That transition persists even if the same late mutation then receives a version conflict. Listening has no artificial wall-clock auto-submission: the player retains and resumes its original source cursor after interruption, as required.

With a server-authoritative deadline, responses first arriving after that deadline are not accepted as if they had been received earlier. The local client keeps its unsynchronized draft and shows a conflict; the server does not trust arbitrary client timestamps to reopen the section. Offline training remains unrestricted. This boundary is explicit rather than silently discarding the draft or inventing proof of its creation time.

## Assessment results

The after-submit GET returns the shared prepared request and contract. The POST body is exactly `{result, provenance}`. Result has exactly integer score_units and nonempty rationale, with the task maximum and step checked by the shared validator.

Provenance requires provider, mode, model, reasoning_effort, revision and contract_sha256; optional fields are request_id, request_sha256 and prompt_version. Model/reasoning uses the existing translation allowlist. Native POST only records personalKey mode and origin `client_personal_key`; it cannot set server_verified or claim backend inference. Trusted server execution uses `record_assessment(..., server_verified=True)` and origin `server_provider`.

Results are immutable per submitted task: an identical replay is a no-op, a conflicting second result is rejected. They update task/section totals without fabricating per-item AI scores from free-form rationale. A section remains pending while any required assessment is missing; all-selected-sections state is grading_pending or graded accordingly. This storage method performs no AI call itself.

## Verification

`python -m unittest backend.exams.test_service -v` uses self-contained small source-integrity fixtures derived from the committed curated profile, without generated output folders or external source downloads. It checks durable restart, staged/published integrity, immutable revisions and transport repacks, source projection privacy, owner isolation, optimistic/idempotent changes, device takeover, deadlines, partial submission, numeric partial credit and assessment readiness/provenance. Actual PDF/audio editorial review belongs to the original digitization pipeline, not those unit fixtures.
