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

- **Select UI coverage** computes the event/path decision. Failure blocks verification.
- **Build iOS test products** has two exhaustive paths. With no UI selected, `ci_ios.py unit` starts
  an owned simulator before compilation, lets first-boot migration overlap the build, discovers
  every unit method and immediately executes the frozen unit plan on that same device. It saves
  diagnostics directly; there is no unit artifact upload/download or second runner/boot. With UI
  selected, the existing producer compiles, separately discovers both bundles and packages Products
  with the complete frozen matrix. The job retains its 25-minute budget.
- **iOS tests (unit/ui-1…ui-8)** runs only when UI coverage is selected. Its consumers restore the
  architecture-bound artifact and execute the exhaustive matrix on separate macOS runners, with
  a fresh simulator for each shard and the existing 25-minute budget. The unit matrix entry still
  runs all unit cases; UI cases retain eight balanced groups.
- **Compile iOS device Release** runs independently, with a 25-minute budget.
- **Build and test** keeps the required-check name. Selection, producer and Release must succeed.
  With UI selected, every matrix job must also succeed. With no UI selected, the matrix must be
  intentionally skipped and the producer must have passed the combined unit execution. Missing
  selection, failed/skipped producer, failed Release or failed/cancelled required matrix jobs fail.
- Backend checks remain independent and required for overall workflow success.

Run [42710302925](https://github.com/rubleuskia/foreignlanguagelearner/actions/runs/42710302925)
measured 128 seconds of simulator compilation and 561 seconds of first boot plus unit discovery.
The old consumer then booted a second fresh simulator for the same unit bundle. The new path removes
that duplicate lifecycle and artifact handoff, while overlapping boot with compilation. Local
validation executed all 273 unit tests successfully on the reused device with zero skipped tests;
hosted before/after wall time still needs measurement. UI-changing PRs retain the matrix path.

Tagging still requires complete successful **main push CI**, including backend, unit and Release jobs. UI is checked on iOS-changing PRs into main and is not repeated
after merge. There is no manual tag bypass or backend-only success path. Total wall time also depends on available runners;
this change does not promise a tag within ten minutes. Historical successful monolithic runs were
already around 23–25 minutes before the latest tests were added.

XCTest producer/consumers use the standard `macos-26` arm64 image with matching Xcode 26.6
and architecture-bound products. The Intel trial booted successfully but exceeded the 240-second
discovery deadline twice for unit tests, and UI discovery also timed out; additional memory did not
produce a successful hosted discovery. Restore the previously working arm64 execution architecture.
Device Release remains independent on `macos-26`.
The former four 14–15-case UI groups exhausted the 20-minute job budget on hosted runners;
eight 7–8-case groups leave more room for boot and Xcode startup. Queued groups may execute in
waves when GitHub runner concurrency is limited; this is not a fixed wall-time guarantee.
No failed test or app launch is automatically retried.

## Release concurrency

PR updates cancel obsolete checks for the same PR. Push verification is grouped by workflow, event
and commit SHA with automatic cancellation disabled, so another main merge cannot cancel the active
run or replace a pending run for an older SHA. Manual runs use a separate event group. Runner capacity
may still queue jobs; verified tags are created only after each corresponding successful main push CI.

## Coverage and artifact integrity

`scripts/ci_ios.py` uses Xcode's flat JSON enumeration, not a hand-maintained test allowlist. It rejects
enumeration errors, disabled/duplicate methods, new unhandled targets and empty shards. Every enabled method in the event-selected targets is assigned exactly once. The current discovery has 273 unit methods and 59 UI methods
(8/8/8/7/7/7/7/7); new methods are assigned automatically.

The plan binds source revision, Xcode build and architecture. A consumer rejects products from a
different checkout/toolchain/architecture. An archive preserves executable permissions and framework
symlinks that ordinary artifact file uploads cannot preserve. A stable product artifact name allows
re-running only failed jobs while reusing the successful build from the same workflow; a producer
re-run overwrites that artifact. Shard diagnostic artifact names include the attempt number.

UI matrix discovery targets and execution shards each receive their own fresh simulator. The
unit-only path owns one fresh simulator for discovery and execution together. In both paths,
`bootstatus -b` readiness must complete before XCTest discovery starts. First-boot system migration has a separate 600-second budget;
a readiness timeout fails without recreating the device and repeating migration. Unit and UI discovery are separate invocations to avoid cross-bundle
testmanagerd bootstrap interference. A user-specified SIMULATOR_ID is prewarmed but never erased/deleted.
Owned devices are cleaned up afterward, including on compilation/discovery/test failure. In the
unit-only path compilation runs during boot; a bounded discovery-only retry creates a fresh device
without repeating compilation, then executes on that successfully discovered device. Actual-test
execution is outside the discovery retry handler. UI compilation/discovery/packaging retain separate steps.

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
# Combined exhaustive unit-only path:
python3 scripts/ci_ios.py unit --derived-data build/UnitCIDerivedData

# Separate UI-matrix reproduction (preserve the previous Tests-unit.xcresult first):
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
