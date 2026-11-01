# Alignment backend

## Source-language contract

`language` accepts exactly `en`, `fr`, `es`, `de`, `it`, `pl`. Codes are lowercase base tags; uppercase, regional tags, unsupported codes and non-string values are rejected. The app canonicalizes its supported regional tags before creating jobs. The pinned `base-guided-v1` profile uses multilingual `base` weights.

The canonical create request, stored job and pinned worker input retain language through start/replay/reconciliation. New worker result manifests also carry `language`; finalization checks it against the job. Legacy manifests lacking the additive field remain readable. Local batch alignment uses the same six codes and requires manifest/CLI equality. Admission limits, capabilities and deployment gates are unchanged; see the six-language matrix in `docs/ALIGNMENT_BENCHMARKS.md` for unexecuted audio-quality checks.


This directory implements the public-test control plane described in
[`docs/AWS_ALIGNMENT_BACKEND_ARCHITECTURE.md`](../../docs/AWS_ALIGNMENT_BACKEND_ARCHITECTURE.md).
It is not deployed by this repository. Deployment requires an explicitly selected development
account in `eu-north-1`, a prebuilt worker image referenced by immutable digest, and recorded
benchmark results for the selected profile.

## Components

- `api.py` exposes the capability-authorized HTTP API. It rejects unknown JSON fields and never
  accepts owner IDs, filenames, model names, offsets, or arbitrary CLI flags.
- `repository.py` owns DynamoDB serialization, idempotency records, job-token binding, conditional
  revisions, and atomic global counters. Product state is never inferred from an S3 listing.
- `finalizer.py` is the only publisher of success. Exit zero without a complete, identity-matched,
  version-pinned manifest becomes `INFRASTRUCTURE_FAILURE`.
- `reconciler.py` runs every five minutes to replay durable start intent, stop overdue/cancelled
  work, release admission, and delete all S3 input/partial-output versions.
- `tools/subtitle-aligner/worker/worker.py` adapts the unchanged local aligner. It downloads pinned
  input versions, verifies bytes and full-file SHA-256, probes duration, captures raw output in
  ephemeral storage, validates cue boundaries, uploads artifacts, and uploads the manifest last.

The worker role is a shared trusted-service role for the temporary backend bucket and job table.
It is not tenant isolation. The bearer capability is stored only as SHA-256 and authorizes exactly
one job. Losing it makes that test job unrecoverable.

## Validation

From the repository root, install `backend/billing/requirements-dev.txt` in a Python 3.12 virtual environment for the full backend suite. `scripts/test-cloud-contracts.sh` adds DynamoDB Local concurrency coverage; see [paid cloud operations](../../docs/PAID_CLOUD_OPERATIONS.md).

```sh
python3 -m unittest discover -s backend -p 'test_*.py' -v
python3 -m unittest discover -s tools/subtitle-aligner -p 'test_*.py' -v
python3 -m compileall -q backend tools/subtitle-aligner/worker
cd infra/alignment && npm ci && npm run build
```

Build the worker only with immutable base image, FFmpeg package, model URL/checksum, and a dependency
lock reviewed for the target architecture. Push it to ECR, obtain its `sha256:` repository digest,
then synthesize with:

```sh
npx cdk synth -c workerRepositoryName=alignment-worker \
  -c workerImageDigest=sha256:DIGEST
```

`ACCEPT_NEW_JOBS` is an operator kill switch on create, signed-upload renewal, and start. Set it to
`false` in the API Lambda configuration to halt new cost. It does not cancel work already running.
Configure approved account-level AWS Budgets alerts separately before enabling work; Stockholm does
not support the `AWS::Budgets::Budget` CloudFormation resource. The regional stack does not create it.
Budget alarms notify; they are not spending cutoffs. Regional admission caps and operational alarms remain.
