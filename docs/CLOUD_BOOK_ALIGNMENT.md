# Cloud book alignment

Implemented for the next operator release; this document does not claim an AWS deployment or
long-book acoustic acceptance. Open Library → + → Cloud alignment. Sign in using the existing
operator/library credentials in Settings. Apple subscription credentials remain separate.

## Files and wizard

1. Choose one MP3/M4A/WAV or a ZIP of 1–500 audio tracks, plus one UTF-8 TXT or EPUB (10 MB).
   TXT is the aligner's native format; the existing `epub_text.py` converts EPUB in spine order.
   PDF, DOCX, SRT and VTT are not alignment source formats. ZIP tracks follow numeric filename
   order, including directories. They must collectively narrate the complete supplied text.
2. **Upload artifacts** stages persistent local copies, checks formats/sizes, and assembles one
   ZIP on iOS using ZIPFoundation. The final ZIP must be ≤100,000,000 bytes, including text and
   manifest. Upload goes directly to private versioned S3 with a signed length and SHA-256.
   The API independently checks actual S3 size/checksum and pins its VersionId before marking
   the request uploaded. A resumed wizard confirms a PUT whose response was lost.
3. **Generate alignment** records durable queue intent. It performs no inference or direct ECS
   invocation. Progress follows server stages, not estimated elapsed time. After success,
   download the SHA-256-verified book ZIP and review/import through the existing book wizard.

Draft metadata, exact submission identity and selected copies live in Application Support's
CloudAlignment directory, excluded from device backup. An interrupted upload can be retried from
the staged ZIP; it does not resume individual byte ranges. Closing/relaunching and reopening the
wizard restores its current request and fetches fresh server status. Server requests remain
discoverable independently of the local draft. New alignment clears the draft, not remote jobs.

## API (Cognito operator JWT)

| Method | Path | Behavior |
| --- | --- | --- |
| POST | `/v1/book-alignments` | UUID Idempotency-Key, title/language/size_bytes/sha256; durable draft |
| GET | `/v1/book-alignments` | Owner-scoped request page, optional cursor |
| GET | `/v1/book-alignments/{id}` | Status, stage progress, attempts, timestamps, safe error code |
| POST | `/v1/book-alignments/{id}/upload` | Renew signed ZIP PUT (15 minutes) |
| POST | `/v1/book-alignments/{id}/complete` | Validate uploaded S3 version; never starts processing |
| POST | `/v1/book-alignments/{id}/start` | Idempotently queue a validated input |
| GET | `/v1/book-alignments/{id}/result` | Version-pinned signed book ZIP and bytes/SHA-256; 410 when removed |

The server derives owner `system` after validating the pinned operator. Neither owner nor arbitrary
S3 URLs/keys are accepted from clients. DynamoDB partitions by owner for later per-user migration;
switching identity derivation, authorizers and local draft partitioning is still required before
multi-user access. Jobs are private to this operator deployment, not publicly accessible.

## Worker, durability and concurrency

The job table is authoritative. Its stream is an outbox to standard SQS; a sparse Recovery index
and a once-per-minute dispatcher replay queued jobs and expired worker leases even after a missed
stream event. SQS deliveries may duplicate. Conditional revision/lease-token writes allow one
worker to claim a job and fence late output after recovery. The worker acknowledges the message
after obtaining its durable lease; heartbeats refresh that lease every ≤20 seconds during compute.
Recovery is independent of SQS's maximum visibility period. Infrastructure failures retry up to
three claimed attempts; deterministic input/alignment errors become terminal with a safe code.

One ECS Fargate service runs one worker, processing one book at a time (2 vCPU, 8 GiB, 40 GiB
ephemeral storage). The default/minimum/maximum count is one, including during rolling updates;
it therefore has idle compute cost. `maxWorkers` and a queue-depth scale-out policy prepare for
later measured capacity increases. Scale-in/draining policy is deliberately not enabled yet.
API/dispatch errors, queue age, DLQ messages and table throttles raise operational alarms.

The worker independently checks pinned ZIP bytes and SHA-256; rejects unsafe/duplicate paths,
symlinks, encrypted archives, >1,000 entries or >1 GB expanded input. It prepares EPUB text,
validates audio with FFprobe, normalizes tracks, joins them in the manifest's client-selected
order, and creates one M4A timeline. Guided multilingual base alignment produces subtitles and
word timings. Cue/word validation precedes publication of an importable single-track book ZIP.
ML runs in a child process so losing the lease or stopping the service terminates inference.
There is no five-minute, one-hour or legacy watchdog duration admission limit on this path.
Finite container memory/disk and model limitations still apply; alignment quality requires review.

S3 artifacts expire after 30 days; database request/history records are retained, encrypted and
protected by PITR/deletion protection. Files are not added automatically to the curated catalog.
The legacy pilot's Step Functions/resources are retained to avoid destructive migration, but its
operator `/v1/alignments` routes are removed. Public-test and paid v2 contracts remain unchanged.

## Release and validation

Build a **new immutable worker image containing these modules**. The old pilot digest does not
contain this queue consumer. Use the normal verified-release Cloud Control preparation/diff/deploy
workflow for the operator stacks in eu-north-1, then build iOS. The existing image-matched Polish
pilot benchmark gate remains a prerequisite for the retained legacy resources; it is not proof
that arbitrary long books or six languages have passed acoustic review. Run representative long
single/multi-track TXT/EPUB jobs, process-loss/recovery and authenticated API acceptance against the
new image before announcing production readiness. Do not substitute the fake-engine tests for it.

Local validation uses the backend moto suite, ZIP/lease/outbox tests, FFmpeg pipeline smoke with
306-second audio and a fake ML engine, CDK assertions, iOS unit tests and wizard relaunch UI test.
No deployment, image publication, release tag, Cognito change or AWS resource creation is included.
