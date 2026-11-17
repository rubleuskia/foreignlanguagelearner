# Decisions and work required before release

## Large books and paid access

Current imports enforce existing size and track limits and return explicit validation
errors when exceeded. This is intentional for the initial operator version. Before release:

- Define free/paid size, duration and chapter limits, entitlement checks and UI messaging.
- Support large books through bounded per-chapter processing, storage and retry budgets.
- Validate a short work, ordinary audiobook and long multi-chapter novel end to end.
- Define mobile-network automatic download policy and confirm interrupted-download behavior.

## Catalog operations and quality

- Deploy the catalog-capable API/worker and populate metadata through manual refresh.
- Verify the complete provider catalog and attribution in real generated packages.
- Confirm expiry policy for cached source files and permanent retention of prepared packages.
- Complete iOS build/device verification and representative alignment/listening acceptance.
- Decide update notifications and explicit replacement flow preserving local vocabulary
  and reading progress; never silently overwrite an imported book.

## Integrate alignment benchmarks into the release pipeline (2026-11-17)

The manually supplied benchmark report is no longer a deployment gate in Cloud Control
or either authenticated CDK assembly. Plan the replacement before re-enabling a gate:

- Build once and bind benchmark runs, fixtures, model/version and evidence to the exact
  immutable worker digest and source revision published by CI.
- Automate representative Polish and multi-chapter book runs; decide which additional
  languages and long-book sizes are release requirements.
- Collect runtime, peak memory, retries, measured AWS cost and alignment-quality metrics.
  Distinguish local/emulated measurements from native Fargate measurements.
- Store raw results and provenance as durable pipeline artifacts, with explicit validity,
  retention, thresholds and failure/retry policy.
- Decide how quality acceptance is performed and recorded; a hand-edited boolean alone
  must not stand in for acoustic review or a defined automated quality evaluation.
- Define cost limits, pipeline permissions and when benchmark jobs run. Re-enable checks
  only after the pipeline produces the required evidence automatically.

Image digest/worker-contract checks, verified release tags, authentication and deployment
plan review remain enforced. Removing the manual gate does not establish acoustic quality.
