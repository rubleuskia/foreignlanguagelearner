# Cloud alignment benchmark gate

**Status:** Required before deployment; no cloud release limit has been validated yet.

**Region:** `eu-central-1`

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

For the selected profile, copy the current Frankfurt rates and calculation date from AWS pricing.
Calculate each job as:

```text
billed task hours * (2 * regional vCPU-hour rate + 8 * regional GiB-hour rate)
+ public IPv4 task time
+ any ephemeral storage above the included 20 GiB
```

The monthly estimate must also include measured ECR storage/pulls, versioned S3 storage and
requests, transfer, API Gateway, Lambda, DynamoDB, Step Functions, logs, alarms, and the scheduled
reconciler. The budget resource is an alert and does not stop spending.
