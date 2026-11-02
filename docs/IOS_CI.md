# iOS CI execution and release tags

The former single 30-minute macOS job compiled the app, ran every unit/UI test sequentially,
then built device Release. Run 41345712143 reached its limit while still executing UI cases;
Release never started. Logs also exposed stale settings/reader assertions, so increasing the
deadline alone would not produce a successful release.

The `CI` workflow now has independent jobs:

- **Build iOS test products** builds the host architecture once, enumerates actual XCTest methods
  and packages Products plus a frozen test plan. Its 25-minute bound covers compilation/enumeration.
- **iOS tests (unit/ui-1…ui-4)** restore that artifact and use `test-without-building` on separate
  macOS machines. All unit cases run in one shard; sorted UI methods are distributed round-robin
  across four shards, spreading the expensive library/reader classes. Each job has a 20-minute bound.
- **Compile iOS device Release** runs independently, with a 25-minute bound.
- **Build and test** preserves the existing required-check name. It succeeds only if the build,
  every matrix shard and Release succeeded; skipped/cancelled/failed dependencies fail the gate.
- Backend checks remain independent and required for overall workflow success.

Tagging still requires complete successful **main push CI**, including all these jobs. There is no
manual tag bypass or backend-only success path. Total wall time also depends on available runners;
this change does not promise a tag within ten minutes. Historical successful monolithic runs were
already around 23–25 minutes before the latest tests were added.

## Coverage and artifact integrity

`scripts/ci_ios.py` uses Xcode's flat JSON enumeration, not a hand-maintained test allowlist. It rejects
enumeration errors, disabled/duplicate methods, new unhandled targets and empty shards. Every enabled
method is assigned exactly once. The current discovery has 273 unit methods and 59 UI methods
(15/15/15/14); new methods are assigned automatically.

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
