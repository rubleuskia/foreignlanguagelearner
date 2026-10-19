# Reading vocabulary validation

Date: 2026-10-18. Base: `origin/main` at `cd02f32`.
Environment: Xcode 26.6, arm64 iPhone 17 Pro simulator, iOS 26.5.

## Results

- Full regression: **134 unit tests and 13 UI tests passed**, zero failures (`ReadingVocabularyReleaseVerification.xcresult`).
- Release simulator build: **BUILD SUCCEEDED**, without DEBUG fixtures.
- Final backup refinements reuse ISO-8601 formatters and defer translation cancellation until successful restore; all 134 unit tests passed again and the final Release build succeeded for these changes.

Result bundles are local generated artifacts under `build/` and are not committed.

## Automated coverage

- The unit suite covers tokenizer normalization and original UTF-16 ranges, separate language namespaces, idempotent irreversible completion, dictionary independence, track/full-book coverage, missing declared subtitle files, stale confirmations and preservation of prior playback position on a failed save.
- Migration coverage creates a persistent store using the exact pre-feature LearningItem/DictionaryEntry model fields, opens it with the additive schema, migrates completed parts, and reopens it again. Existing identity, position, notes and learning levels remain intact.
- Backup coverage tests v1/v2 compatibility, v3 union and translations-only behavior, knowledge-only restoration into an empty library, duplicate/noncanonical forms, unsupported tokenizer versions and atomic failures for both new and existing dictionary/word records.
- Import coverage creates real raw and manifest ZIPs, previews their staged TXT without committing library files, detects changed external TXT, checks the prepared transcript fingerprint, and parses single-file SRT without counting timestamps or markup.
- UITextView coverage verifies independent word foreground/cue backgrounds, selected-range preservation, deferred style updates and restoration of base foreground when words become known.
- Reader UI coverage cancels chapter confirmation, confirms chapter completion, checks the changed new-word count in Full text, confirms whole-book completion and verifies both completion actions become disabled. Existing dictionary, learning, file-picker and explanation UI tests are included in the full regression run.

## Simulator timing samples

These are Debug test samples, not physical-device or worst-case performance guarantees.

| Input | Result |
| --- | --- |
| 2,200,000-byte repeated Unicode text | Tokenization approximately 0.6 seconds, 5 distinct forms; cancellation checked separately. |
| 9,900,000-byte full TXT plus 100 SRT tracks | Preparation approximately 2.90 seconds; confirmation revalidation plus save approximately 2.85 seconds. All tracks and the book completed; duplicate words counted once. |

The large-book fixture has repetitive vocabulary (six unique forms after combining sources). It tests text volume and track coverage; it does not establish worst-case insertion cost for hundreds of thousands of distinct forms. File reading and tokenization run outside the main actor. Completion/backup commits are synchronous atomic main-context saves; performance on a physical iPhone, peak memory and playback frame responsiveness have not been profiled in this environment.

## Reproduction

Generate the project using `scripts/bootstrap.sh`, then run `scripts/test.sh` with an available iPhone simulator. The same suite can be run with `xcodebuild test -project ForeignLanguageLearner.xcodeproj -scheme ForeignLanguageLearner -destination 'platform=iOS Simulator,id=<available device UUID>' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO`.

For a production configuration build: `xcodebuild build -project ForeignLanguageLearner.xcodeproj -scheme ForeignLanguageLearner -configuration Release -sdk iphonesimulator -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO`.

## 2026-10-19 — Indexed vocabulary and library badges

Implementation details and deviations from the original proposed outbox/writer design are recorded in `READING_VOCABULARY_INDEX_ARCHITECTURE.md`.

- Added source-cache reuse, exact Set reference comparisons, language isolation, idempotent postings, missed-delivery recovery, cache rebuild, changed/missing files, compact Unicode position-cache round trips, legacy per-word-store migration, 50,000-form completion/export/restore, and a 100-book shared-vocabulary test.
- The reading UI test now verifies the library's new-word count before reading and the total-word count after whole-book completion, alongside chapter counts and the highlight toggle.
- Full regression initially passed 142 unit tests and 12/13 UI tests. The unrelated inline-explanation test failed on its second expand assertion; it passed unchanged in an isolated rerun alongside the reading UI test. This transient failure is retained here rather than describing the first run as wholly green.
- Final verification: **143 unit tests passed** after the background-read and stale-result guards; the final unsigned Release simulator build succeeded. All 13 UI scenarios have passed across the full run and unchanged isolated rerun (the initial flake is described above).
- A separate persistence test verifies opening the previous three-model store with the new batch model, retaining old forms/dates, writing a new batch and reopening the combined data.

Debug simulator timing samples (iPhone 17 Pro, iOS 26.5, Xcode 26.6):

| Scenario | Observed time |
| --- | --- |
| 9.9 MB TXT + 100 subtitle tracks, cold prepare | 2.91 s |
| Same book, cached revalidation + atomic completion | 28.5 ms (previous implementation: 2.85 s) |
| 50,000 distinct forms, warm prepare + completion | 56.9 ms |
| 50,000-form knowledge delta, projection update | 190.9 ms off MainActor |
| 100 books, 1,000 shared forms learned, 100,000 affected memberships | 19.9 ms off MainActor |

The 50k-form test asserts only 25 batch models are saved and that warm prepare/complete does not increment the source tokenization counter. The 100-book test asserts exactly 100,000 visited postings and no further membership visits on reconciliation with unchanged knowledge. Tests also compare every resulting count against a Set difference reference.

These are single local samples, not physical-device p50/p95 guarantees. No physical iPhone memory/frame profile was available. Initial indexing still reads every source once; the UITextView still owns the whole document. Startup knowledge loading now uses a background read-only context. Large backup preview/export/restore still performs main-context work, although restore groups additions into compact batches. Native selection and existing following/foreground regression tests remain required.
