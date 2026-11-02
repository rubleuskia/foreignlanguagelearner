# iOS CI execution and release tags

The former single 30-minute macOS job compiled the app, ran every unit/UI test sequentially,
then built device Release. Run 41345712143 reached its limit while still executing UI cases;
Release never started. Logs also exposed stale settings/reader assertions, so increasing the
deadline alone would not produce a successful release.

UI tests run **only on `pull_request` events whose base branch is `main` and whose diff touches iOS inputs**. Pushes to `main`
(including merges that produce release tags), manual runs and reusable publishing runs keep backend
contracts, all unit tests and device Release compilation, without UI discovery or execution.

| Event | Unit tests | UI tests | Device Release / backend |
| --- | --- | --- | --- |
| PR into `main`, iOS inputs changed | All | All eight shards | Required |
| PR into `main`, docs/backend/tooling only | All | Not scheduled | Required |
| Push/merge into `main` | All | Not scheduled | Required |
| Other PR, manual or reusable run | All | Not scheduled | Required |

`Select UI coverage` reads the PR event's base/head commit SHAs and compares head against their
Git merge base. iOS inputs are `App/`, `Tests/UI/`, `.swiftpm/`, the app's Xcode project/workspace,
`project.yml`, `Package.swift`, `Package.resolved` and `scripts/bootstrap.sh`. These cover app code,
resources, localizations, build/dependency configuration and UI scenarios. Documentation, backend,
infrastructure, agent rules, CI tooling and unit-only changes do not select UI. Renames consider both
removed and added paths, including moving a file out of App. A missing/invalid diff fails CI instead
of silently omitting UI. Full Git history avoids file-list pagination limits and handles fork PRs.

The `CI` workflow has independent jobs:

- **Select UI coverage** computes the event/path decision before the test plan. Failure blocks the
  producer and therefore the aggregate; it cannot become a successful skip.

- **Build iOS test products** builds the host architecture once, enumerates actual XCTest methods
  and packages Products plus a frozen test plan. When UI is not selected, `plan --unit-only`
  enumerates only the unit bundle; test products still compile together. Its 25-minute bound covers compilation/enumeration.
- **iOS tests (unit/ui-1…ui-8)** restore that artifact and use `test-without-building` on separate
  macOS machines. All unit cases run in one shard; sorted UI methods are distributed round-robin
  across eight shards, spreading the expensive library/reader classes. Each job has a 25-minute bound, including boot, Xcode launch and diagnostic upload.
- **Compile iOS device Release** runs independently, with a 25-minute bound.
- **Build and test** preserves the existing required-check name. It succeeds only if the build,
  every event-selected matrix shard and Release succeeded; skipped/cancelled/failed dependencies
  fail the gate. UI shards are absent from the main matrix, not accepted as failed/skipped prerequisites.
- Backend checks remain independent and required for overall workflow success.

Tagging still requires complete successful **main push CI**, including backend, unit and Release jobs. UI is checked on iOS-changing PRs into main and is not repeated
after merge. There is no manual tag bypass or backend-only success path. Total wall time also depends on available runners;
this change does not promise a tag within ten minutes. Historical successful monolithic runs were
already around 23–25 minutes before the latest tests were added.

XCTest producer/consumers use the standard `macos-26-intel` image (4 CPU, 14 GB RAM), with
matching Xcode 26.6 and x86_64 products. Device Release remains independent on `macos-26`.
The former four 14–15-case UI groups exhausted the 20-minute job budget on hosted runners;
eight 7–8-case groups leave more room for boot and Xcode startup. Queued groups may execute in
waves when GitHub runner concurrency is limited; this is not a fixed wall-time guarantee.
No failed test or app launch is automatically retried.

## Coverage and artifact integrity

`scripts/ci_ios.py` uses Xcode's flat JSON enumeration, not a hand-maintained test allowlist. It rejects
enumeration errors, disabled/duplicate methods, new unhandled targets and empty shards. Every enabled method in the event-selected targets is assigned exactly once. The current discovery has 273 unit methods and 59 UI methods
(8/8/8/7/7/7/7/7); new methods are assigned automatically.

The plan binds source revision, Xcode build and architecture. A consumer rejects products from a
different checkout/toolchain/architecture. An archive preserves executable permissions and framework
symlinks that ordinary artifact file uploads cannot preserve. A stable product artifact name allows
re-running only failed jobs while reusing the successful build from the same workflow; a producer
re-run overwrites that artifact. Shard diagnostic artifact names include the attempt number.

Each discovery target and test shard receives its own fresh simulator, with explicit `bootstatus -b`
readiness before Xcode starts. First-boot system migration has a separate 600-second budget;
a readiness timeout fails without recreating the device and repeating migration. Unit and UI discovery are separate invocations to avoid cross-bundle
testmanagerd bootstrap interference. A user-specified SIMULATOR_ID is prewarmed but never erased/deleted.
Owned CI devices are cleaned up afterward. Compile, discovery and packaging have separate workflow steps.

Xcode can exit successfully with a partial manifest after losing testmanagerd. Such a manifest is
rejected, including placeholder bundle identifiers. Only XCTest discovery bootstrap loss/timeout after device readiness gets one
bounded attempt on another fresh device; **actual test methods are never retried automatically**.
Unknown discovery failures/disabled selected tests fail immediately. Both attempt manifests and
enumeration xcresults are retained, and failed discovery invalidates the old frozen plan.

Each test has an enabled default 180-second allowance and a 240-second maximum. There are no automatic
retries or silently quarantined UI failures. Each shard writes an xcresult and JSON summary; the helper
checks that the reported test count matches the planned methods, rejecting a successful empty/partial
run. Matrix fail-fast is disabled so other shards can finish and save their diagnostics.

## Reproduce locally

```sh
python3 -m unittest discover -s Tests/CI -p 'test_*.py' -v
python3 scripts/ci_ios.py build
mkdir -p build/ci-testing
tar -xzf build/ios-test-products.tar.gz -C build/ci-testing
python3 scripts/ci_ios.py run --shard unit
python3 scripts/ci_ios.py run --shard ui-1
```

Use the same Xcode and architecture as the producer. `SIMULATOR_ID` selects a particular available
iPhone; otherwise the helper chooses one. Run different shards concurrently only on different
simulators. `build/Tests-<shard>.xcresult` must not already exist; preserve/move an old report before
repeating a local shard. `bash scripts/test.sh` remains the ordinary local all-tests command.

Before merging, check every CI job rather than the aggregate name alone. On a failure download
`test-results-<shard>-<attempt>` and its frozen plan. Re-run failed jobs only for a transient runner
failure; fix deterministic UI or application failures. After a merge, a verified main tag is created
only when the corresponding complete main CI succeeds.

The UI assertions now scroll to the personal-key field in the longer settings form, reach New words
through Book actions, and verify completion counts on the library where those counts are presented.
They continue covering cancellation, chapter completion and whole-book completion; removed reader
controls and the removed text-source picker are no longer assumed to exist.

Primary contracts: [Apple XCTest enumeration](https://developer.apple.com/documentation/xcode-release-notes/xcode-15-release-notes),
[Apple test selection](https://developer.apple.com/documentation/xcode/running-tests-and-interpreting-results),
[GitHub matrix jobs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/run-job-variations),
[sharing workflow artifacts](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts).
