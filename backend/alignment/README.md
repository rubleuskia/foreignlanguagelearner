# Alignment backend

This directory implements the public-test control plane described in
[`docs/AWS_ALIGNMENT_BACKEND_ARCHITECTURE.md`](../../docs/AWS_ALIGNMENT_BACKEND_ARCHITECTURE.md).
It is not deployed by this repository. Deployment requires an explicitly selected development
account in `eu-central-1`, a prebuilt worker image referenced by immutable digest, and recorded
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

From the repository root:

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
  -c workerImageDigest=sha256:DIGEST -c monthlyBudgetUsd=50
```

`ACCEPT_NEW_JOBS` is an operator kill switch on create, signed-upload renewal, and start. Set it to
`false` in the API Lambda configuration to halt new cost. It does not cancel work already running.
Budget alarms notify; they are not spending cutoffs.
