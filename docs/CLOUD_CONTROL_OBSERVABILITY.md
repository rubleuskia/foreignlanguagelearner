# Cloud Control observability — work in progress

This draft captures the implementation stage stopped at the user's request. It is not ready
for merge or deployment. No AWS resources were created or changed.

## Implemented source

- Local Swagger UI 5.35.0 with its license/NOTICE, OpenAPI generated from deployed API Gateway
  routes, JSON request schemas and a same-origin manual relay. The relay uses only the configured
  project's endpoint, rejects arbitrary URLs, and does not retry submissions. External validation
  and browser authorization persistence are disabled. The configured token file or explicit
  Swagger bearer authorization can be used; the saved-token checkbox permits unauthenticated tests.
- Project resource discovery, S3 file pages with sizes/prefixes, including imported library storage
  and CDK storage. Listings describe current versions and page totals, not total versioned usage.
- Monthly Cost Explorer service/day summaries, an independent AWS plan/credit summary, runtime
  dates, account scoping, Decimal arithmetic and caching. Missing/denied data is distinct from zero.
- Alignment request/worker-attempt counts and size/runtime/queue metrics from retained legacy
  and new book job records. Reports expose time-window/TTL/scan limits and missing durations.
- API Gateway 5xx metrics and paged CloudWatch error logs, with common credential redaction.
- Deployed/candidate release comparison, book component presence, and structured resource/template
  changes saved with prepared CDK plans. The existing verified-tag and deployment guards remain.
- Dashboard sections and links for these views. No browser or live integration acceptance yet.

## Remaining before this PR is ready

1. Add focused automated tests for monitoring: S3/CE/DynamoDB/API Gateway pagination, runtime
   dates and cost arithmetic, partial/denied sources, retention limits, legacy/book timing fields,
   scoped resource discovery, unknown buckets/groups and credential redaction.
2. Add OpenAPI/manual-relay HTTP tests: valid path parameters, traversal/SSRF rejection,
   origin/CSRF guards, saved/explicit/absent authorization, forwarded 500 responses and no retries.
   Verify the schemas/examples against the actual deployed operator/paid contracts.
3. Validate SDK operation/paginator support against the pinned local dependencies, then exercise
   real read-only S3, Cost Explorer/Free Tier, DynamoDB and CloudWatch views using `fll-control`.
   Confirm required read permissions and source-specific access errors without changing IAM.
4. Open the dashboard and Swagger in a browser. Verify every section, actual Try it out behavior,
   CSP compatibility, pagination/filter changes, responsive layout and configuration/cache changes.
5. Test deployment-summary accuracy: prepared/current templates, output/parameter changes,
   stale/expired/config-changed plans, missing local commits, retained resources and worker-image
   prerequisites. Improve incomplete/stale-plan presentation where needed.
6. Reconcile with alignment PR #95 after it merges. This branch started from main before #95;
   the dashboard supports its expected resource IDs/job schema but that integration is unverified.
   Preserve the newer alignment health route when merging the branches.
7. Finish documentation/permission guidance and vendor provenance checks; run the full relevant
   tests/CI and resolve findings, then mark the PR ready. Do not deploy AWS or create release tags
   as part of completing this dashboard PR.

The existing Cloud Control regression suite and Python/JavaScript syntax checks are the current
stage checks. New diagnostic scenarios, browser QA and live AWS reads are still pending.
