# Cloud Control diagnostics and manual API tests

Run `bash scripts/cloud-control.sh` and open http://127.0.0.1:8767. Diagnostics stay in the
existing local server; startup never deploys AWS or submits inference. Configure the project ID,
`eu-north-1` and an authenticated SDK profile in Settings. STS must match the configured project.

## Views

- **Swagger API** opens `/swagger`. Its OpenAPI document is generated from the selected deployed
  API Gateway's live routes; absent routes are not advertised. Swagger UI 5.35.0 is bundled locally
  with license, NOTICE and hash provenance. No CDN, external validator or persistent browser
  authorization is used. **Try it out** sends one explicit request through a same-origin relay,
  avoiding production CORS changes. The relay rejects arbitrary endpoints, unknown routes and
  traversal, bounds requests/responses, refuses redirects and never retries. Use explicit bearer
  authorization or the configured owner-only `access_token_file`; uncheck saved-token use to test
  anonymous access. Valid POSTs can spend quota or enqueue work: Execute is the operator's explicit
  request. JSON operations are supported; upload binary artifacts through the app/presigned S3
  flow. Real upstream error status/body, including 500, is preserved.
- **S3 files** lists discovered project buckets, including imported book-library storage and the
  CDK bootstrap bucket. Choose a prefix and use the next-page button. Each page contains at most
  100 objects with byte size, modification time and storage class. Totals cover loaded current
  versions, not old versions, unfinished multipart uploads or the entire bucket.
- **Alignment** reads retained legacy and queue-based book requests for 7/30/90 days, grouped by
  creation time. It distinguishes requests from worker attempts, shows input bytes, status,
  mean/p95 elapsed processing and queue wait. Processing runs from first worker claim through
  completion, including retries; missing timing remains unknown. Legacy TTL limits history.
  Scans stop after 50 pages/10,000 returned records per table; partial coverage is marked and
  only the newest 200 detail rows are displayed. This is operational usage, not a billing ledger.
- **AWS costs** shows current-month UnblendedCost by service/day and the independent AWS plan,
  remaining credits and expiration. Dates come from the runtime clock; CE's end date is exclusive.
  Costs are scoped to the selected project, include credits/refunds, may be estimated/delayed,
  and are cached for 15 minutes. OpenAI provider spending is separate. Denied/empty sources are
  unavailable, never presented as a zero bill. Global billing APIs use their us-east-1 endpoint;
  no Regional resources are created there.
- **Errors and logs** shows API Gateway request/5xx sums for 1/24 hours and pages of error events
  from one discovered CloudWatch log group. Access logs require an actual JSON status 500–599;
  worker/function logs use an error-pattern filter. Missing metrics or empty pages do not prove
  zero errors. Credential patterns are redacted, but this remains private operational data.
- **Versions and deploy** compares candidate and deployed revisions, identifies missing book
  components and worker-image prerequisites, and displays resource/property/output changes from
  the actual prepared/current templates. Retain removals are labelled. An absent prepared plan
  is not an exact deployment preview. Expired plans, changed configuration/Region or changed
  stack baseline are marked invalid; existing deploy gates still revalidate source, CI, assets
  and permissions. Read the full CDK diff for IAM/replacement consequences. A code tag does not
  build/publish a new aligner image.

Read caches are scoped by configuration; configuration changes clear visible data and invalidate
in-flight results. Failed reads retry after at most 15 seconds. Release metadata is cached for
30 seconds and invalidated after an explicit tag refresh, avoiding repeated Git scans every poll.

## Read permissions

Existing identity/deployment gates are unchanged. Diagnostics need these additional reads on the
selected project's resources; the panel does not grant them or alter IAM:

| Source | Actions |
|---|---|
| Identity/discovery | `sts:GetCallerIdentity`, `cloudformation:DescribeStacks`, `cloudformation:ListStackResources`, `cloudformation:GetTemplate` |
| S3 | `s3:ListBucket` on discovered buckets |
| Alignment records | `dynamodb:Scan` on discovered alignment request/job tables |
| API route descriptions | `apigateway:GET` for the selected HTTP API routes |
| Metrics/logs | `cloudwatch:GetMetricStatistics`, `logs:FilterLogEvents` on discovered log groups |
| Costs/plan | `ce:GetCostAndUsage`, `freetier:GetAccountPlanState` |

The existing overview also reads CloudWatch alarms. A source denied by the project's policies is
reported separately; do not broaden access simply to suppress a warning. Listings/metrics can
incur normal AWS read/API charges. Keep the service bound to loopback and state files private.

## Validation

```sh
python -m unittest tools.cloud_control.test_control tools.cloud_control.test_observability scripts.test_alignment_benchmark -v
node --check tools/cloud_control/web/app.js
node --check tools/cloud_control/web/monitor.js
node --check tools/cloud_control/web/swagger.js
```

Tests use botocore operation validation, moto, bounded local HTTP servers and fake upstream calls:
pagination, decimal arithmetic, scoped discovery, partial/denied reads, plan invalidation,
credential redaction, route/path guards, auth selection, HTTP 500 forwarding and no retries.
They never deploy or invoke paid inference. For reproducible browser QA without AWS:

```sh
python -m tools.cloud_control.test_web_fixture --port 8770
```

That separate server labels every page **OFFLINE TEST**, disables operation execution and returns
fixture telemetry/manual responses. It is not evidence of real spend or deployment health.
Browser acceptance covers all diagnostic sections, S3 pagination, Swagger Execute 200/500 and
desktop/mobile layout. Live reads require a renewed AWS session and cannot establish long-book
alignment quality or successful deployment of a candidate release.

Live read-only acceptance on 2026-11-14 succeeded for resource discovery, S3 listings, retained
legacy alignment records, Cost Explorer/Free Tier, CloudWatch metrics/access logs and live routes.
The anonymous health request returned 401 as expected. The project still runs the legacy pilot;
new book metrics/deployment changes are covered by SDK/template fixtures until that pipeline is
deployed. No paid inference, alignment submission, release publication or AWS mutation was tested.
