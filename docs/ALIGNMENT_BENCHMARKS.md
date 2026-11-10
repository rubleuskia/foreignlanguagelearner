# Cloud alignment benchmark gate

**Status:** Required before deployment; no cloud release limit has been validated yet.

**Region:** `eu-north-1`

**Candidate task:** Linux/x86_64 Fargate, 2 vCPU, 8 GiB memory, 20 GiB ephemeral storage

The implementation accepts declarations up to 1,000,000,000 audio bytes and rejects probed audio
over 3,600 seconds. These are development admission ceilings, not evidence that the current
`base-guided-v1` worker processes a 60-minute fixture within its 3-hour-45-minute watchdog and
memory limit. Do not deploy the public endpoint until the maximum-length row passes with measured
headroom. Lower admission or increase the measured task profile through a reviewed decision if it
does not.

Use matching, rights-cleared fixtures and an image referenced by ECR digest. Run each combination
from a cold task at least three times. Record the slowest wall time and highest memory/disk value.
Manually review timing quality; a structurally valid subtitle is not proof of correct alignment.

| Date | Image digest | FFmpeg | Model checksum | Mode | Fixture | Audio bytes | Duration | Task billed time | Worker wall time | Peak RSS | Peak disk | Review result | Error code |
|---|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
| pending | pending | pending | pending | base/direct | matching 5 min | pending | 300 s | pending | pending | pending | pending | pending | pending |
| pending | pending | pending | pending | base/guided | matching 5 min | pending | 300 s | pending | pending | pending | pending | pending | pending |
| pending | pending | pending | pending | small/guided | matching 5 min | pending | 300 s | pending | pending | pending | pending | pending | pending |
| pending | pending | pending | pending | base/direct | matching 30 min | pending | 1,800 s | pending | pending | pending | pending | pending | pending |
| pending | pending | pending | pending | base/guided | matching 30 min | pending | 1,800 s | pending | pending | pending | pending | pending | pending |
| pending | pending | pending | pending | small/guided | matching 30 min | pending | 1,800 s | pending | pending | pending | pending | pending | pending |
| pending | pending | pending | pending | base/direct | matching 60 min | pending | 3,600 s | pending | pending | pending | pending | pending | pending |
| pending | pending | pending | pending | base/guided | matching 60 min | pending | 3,600 s | pending | pending | pending | pending | pending | pending |
| pending | pending | pending | pending | small/guided | matching 60 min | pending | 3,600 s | pending | pending | pending | pending | pending | pending |

Record failure behavior separately for mismatched text, insufficient guided anchors, malformed
audio, checksum mismatch, task timeout, SIGTERM, and forced OOM. Confirm that each run releases the
active counter once, never starts a second inference attempt, and exposes no raw text in CloudWatch
or Step Functions history.

For the selected profile, copy the current Stockholm rates and calculation date from AWS pricing.
Calculate each job as:

```text
billed task hours * (2 * regional vCPU-hour rate + 8 * regional GiB-hour rate)
+ public IPv4 task time
+ any ephemeral storage above the included 20 GiB
```

The monthly estimate must also include measured ECR storage/pulls, versioned S3 storage and
requests, transfer, API Gateway, Lambda, DynamoDB, Step Functions, logs, alarms, and the scheduled
reconciler. The budget resource is an alert and does not stop spending.

## Private operator pilot

The private first stage is a separate measured envelope: Polish only, at most 300 seconds of
probed audio. `OPERATOR_ALIGNMENT_PILOT=pl-300-v1` is set on the operator alignment Lambdas and
worker task by CDK. Admission rejects other languages before creating uploads; FFprobe rejects
actual audio longer than 300 seconds before inference, including files with misleading metadata.
The shared account/anonymous versions retain their existing six-language/60-minute limits.

For this pilot, use a matching 300-second Polish fixture, run it cold at least three times and
record provenance/input hashes, slowest wall time, highest memory/disk use, failures and output
coverage. Listen to the beginning, middle, end and every flagged region before accepting quality.
Do not silently promote old alignment output or a model-loading check to acceptance evidence.
The full six-language/60-minute matrix below applies to the broader release, not this pilot.

The dashboard and operator CDK require a report matching the exact image digest, with
`scope: "operator-pl-300-v1"`, `maxAudioSeconds: 300`, positive `maxJobCostUsd`, and `languages.pl`
containing `audioSeconds: 300`, integer `runs` ≥3, `qualityAccepted: true`, positive finite
`runtimeSeconds` ≤13500 and `peakMemoryMiB` ≤8192, plus finite nonnegative `costUsd` within the
stated budget. Attach the raw runs and review evidence; field validation is not quality review.
Local Docker measurements must identify emulation/hardware and cannot be described as Fargate
billed measurements. Leave unmeasured cost and unreviewed quality pending.

Run preliminary offline Docker measurements with:

```sh
python scripts/alignment-benchmark-local.py \
  --image YOUR_ECR_REPOSITORY@sha256:YOUR_PUBLISHED_DIGEST \
  --audio /absolute/path/polish-300s.wav \
  --text /absolute/path/matching-transcript.txt \
  --output /absolute/path/new-local-measurements
```

The helper starts three separate CPU-only containers with networking disabled, executes the real
`base/guided` engine and retains subtitle outputs, logs, input hashes, container wall time and
Linux cgroup peak memory when available. It records failures and stops rather than retrying them.
It produces **local evidence**, with quality unaccepted and cloud cost unset, not a deployable
acceptance report. Supply your own matching fixture and review its recording/text rights.

## Six-language audio-quality release matrix

Status on 2026-10-27: **not executed**. No matching real-audio fixtures or downloaded model weights were available in this checkout. Existing historical English/Polish smoke results in the conversion reports are not new measurements of these rows. Mocked six-language tests verify accepted codes, pinned worker input, idempotency and punctuation/text reconstruction only.

Use a rights-cleared 3–5 minute excerpt for each row, including ordinary speech, punctuation, apostrophes where applicable, repeated words, and one difficult passage. Store provenance/license, source URL or recording consent, exact UTF-8 transcript and SHA-256 hashes of both inputs beside the result. Run local `batch_align.py --manifest <fixture>/manifest.json --output <new-dir> --model base --guided --device cpu --language <code>`; each fixture manifest must declare that code. Pin Python/dependency versions, model checksum, hardware and git commit. Repeat with the candidate deployed image/profile only when deployment is separately authorized.

| Language | Profile/model | Fixture provenance + hashes | Failures | Untimed words / total | Manual listening findings | Status |
|---|---|---|---|---|---|---|
| English (`en`) | base-guided-v1 / multilingual base | pending | unmeasured | unmeasured | pending | not run |
| French (`fr`) | base-guided-v1 / multilingual base | pending | unmeasured | unmeasured | pending | not run |
| Spanish (`es`) | base-guided-v1 / multilingual base | pending | unmeasured | unmeasured | pending | not run |
| German (`de`) | base-guided-v1 / multilingual base | pending | unmeasured | unmeasured | pending | not run |
| Italian (`it`) | base-guided-v1 / multilingual base | pending | unmeasured | unmeasured | pending | not run |
| Polish (`pl`) | base-guided-v1 / multilingual base | pending | unmeasured | unmeasured | pending | not run |

Record start/end drift and word-boundary errors after listening to the beginning, middle, end and flagged untimed regions; record every dropped/repeated word and any run failure. Review all flagged coverage rather than treating parser success as timing quality. This matrix supplements the maximum-duration/memory/disk gate above and does not authorize cloud deployment or claim a validated quality threshold.
