# Private Polish audio measurements

This is a prepared operational workflow, not a completed benchmark. Native cloud execution needs
separate authorization under [the benchmark procedure](ALIGNMENT_BENCHMARKS.md). A local x86 image
run on the ARM development host took 213 seconds to transcribe 26.1 seconds of audio and was stopped;
it does not establish Fargate performance. No accepted quality/cost report has been generated.

The separate `bin/benchmark.ts` assembly creates one private versioned/encrypted S3 bucket, a VPC
with one verified Stockholm public subnet and S3 gateway endpoint, a security group without inbound
rules, an ECS cluster/task definition, scoped task/execution roles and a seven-day log group.
There is no API, NAT gateway, ECS service or application data table. Tasks use 2 vCPU, 8 GiB,
Linux/x86_64 and the immutable reviewed ECR digest. This stack uses BootstraplessSynthesizer and
needs no CDKToolkit or application deployment. An empty cluster does not automatically start work.

## Prepare and review

Use the existing CLI profile, confirm the project/selected Region and spend status in AWS Settings,
and verify the availability zone. The benchmark is restricted to eu-north-1. Supply a matching
300-second PCM WAV, exact UTF-8 transcript and provenance/hashes. Preserve recording attribution.
The development fixture is an excerpt of Bolesław Prus, *Lalka*, chapter II, read by Albert Osik,
directed by Dominik Lehman, from [Wolne Lektury](https://wolnelektury.pl/katalog/lektura/lalka-tom-pierwszy/).
Its excerpt boundaries derive from historical alignment and need listening review. It is local
evidence, not an independently timed gold reference; do not commit the recording to the repository.

```sh
cd infra/alignment
node_modules/.bin/cdk --app 'npx ts-node bin/benchmark.ts' synth --no-lookups --json \
  -c benchmarkProject=YOUR_PROJECT_ID -c benchmarkZone=YOUR_VERIFIED_STOCKHOLM_ZONE \
  -c workerRepositoryName=fll-alignment-worker \
  -c workerImageDigest=sha256:YOUR_PUBLISHED_IMAGE_DIGEST \
  --output /absolute/path/new-benchmark-assembly > /absolute/path/benchmark-template.json
```

Inspect the generated IAM policies and resources. `npm test` checks the absence of an API, ECS
service, NAT gateway, Lambda and bootstrap dependency, plus the private bucket/task envelope.
CDK synthesis/type checks and AWS ValidateTemplate passed for the prepared development template.
These checks do not prove quotas, service availability or provisioning permissions. Separate
cfn-lint/cfn-guard compliance checks were not run because those tools are not installed.
No durable CloudTrail trail was found during read-only preparation; durable audit retention was
not configured or changed. Do not describe this as a full security/compliance validation.

## Authorized execution only

After approving the concrete template, create only the disposable measurement stack:

```sh
aws cloudformation deploy --profile fll-control --region eu-north-1 \
  --stack-name ForeignLanguageLearnerAudioBenchmark \
  --template-file /absolute/path/benchmark-template.json --capabilities CAPABILITY_IAM
```

From the repository root, use the project virtual environment with boto3 installed:

```sh
.cloud-control/venv/bin/python scripts/alignment-benchmark-aws.py \
  --project YOUR_PROJECT_ID --audio /absolute/path/polish-300s.wav \
  --text /absolute/path/matching-transcript.txt --output /absolute/path/new-aws-evidence
```

The controller refuses another active run, uploads hashed input/driver files, and starts exactly
three sequential cold tasks. Each driver downloads/verifies fixtures, loads the bundled model,
probes actual duration and executes the real base/guided engine. Logs with source material stay
in private S3 evidence. It saves outputs and measurement failures without inference retries.
The engine alarm is 15 minutes; the controller attempts to stop a task after 20 minutes including
startup/pull. Keep the controller running; stop operations and network failures can delay teardown.
The driver cannot approve its own quality: raw results contain `qualityAccepted: false` and
`costUsd: null`. A successful engine exit alone never generates a deployable acceptance file.

Record slowest worker/container time, peak cgroup memory, observed peak disk and ECS pull/stop
timestamps. Calculate cost using current regional rates and the billed duration (including image
pull), plus IPv4 and other service usage. On 2026-11-10 the official Stockholm on-demand Linux/x86
rates were $0.0445/vCPU-hour and $0.0049/GiB-hour: 2 CPU and 8 GiB cost $0.1282/task-hour.
At three 20-minute tasks this is $0.1282 compute plus about $0.005 IPv4; S3/logs/other usage are
additional. This is a planning calculation, not measured billing or a hard spending limit.
Sources: [regional ECS price list](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonECS/current/eu-north-1/index.json),
[Fargate billing](https://aws.amazon.com/fargate/pricing/), [IPv4](https://aws.amazon.com/vpc/pricing/).

Listen to beginning/middle/end and every flagged interval before accepting quality. Only then
assemble the image-matched report described in OPERATOR_CLOUD.md and set its absolute path in
Cloud Control. This does not authorize publishing the application API.

## Cleanup after retaining evidence

Download/inspect all run results first. The helper verifies the project, stack purpose tag and
stack/bucket identity against retained local evidence, refuses active tasks, clears only that
temporary bucket's object versions, then requests deletion of that stack:

```sh
.cloud-control/venv/bin/python scripts/cleanup-alignment-benchmark.py \
  --project YOUR_PROJECT_ID --evidence /absolute/path/new-aws-evidence
aws cloudformation wait stack-delete-complete --profile fll-control --region eu-north-1 \
  --stack-name ForeignLanguageLearnerAudioBenchmark
```

Keep local evidence, the original source recordings and the existing ECR repository/image.
