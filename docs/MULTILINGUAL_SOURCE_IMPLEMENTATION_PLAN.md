# Multilingual source languages — implementation plan

Date: 2026-10-27. Status: implemented for review; real-audio benchmark gate remains pending.

## Product contract

- Supported new-book source languages: English (`en`), French (`fr`), Spanish (`es`), German (`de`), Italian (`it`), Polish (`pl`). Translation and explanations remain Russian (`ru`); interface localization is outside scope.
- Source language is a persisted book attribute and an independent persisted dictionary-entry attribute. New entries inherit their book's language. Deleting a book never removes an entry's language or learning history.
- Dictionary and Practice expose a dropdown backed by the same persisted active source-language selection. Changing it on either screen changes the other. No mixed-language All mode for these workflows.
- All dictionary searches, counts, level/readiness filters, practice candidates, quick starts, learnt reviews and results operate within that source language.
- Two books with ten saved entries each in different languages produce two independent ten-entry groups. Books in the same language share studied reading forms; books in different languages do not.
- Reading forms, unique source words and saved dictionary entries remain distinct metrics: a saved entry can be a phrase.
- Backend alignment, its API contract, local alignment tools and relevant infrastructure/tests are in scope. Deployment is not required or authorized by this plan; retain the existing deployment gate.

## 1. Shared language model and import

Primary files: `App/Models/SourceLanguage.swift`, `App/Models/LibraryModels.swift`, `App/Views/BookImportWizard.swift`, `App/Views/ImportItemView.swift`, `App/Views/ReaderView.swift`, `App/Services/BookImportService.swift`.

1. Introduce one canonical supported-source registry and language-code normalization. Define handling of regional tags explicitly: use the supported base language for grouping without silently reinterpreting unrelated legacy tags. Preserve original metadata when required for compatibility. Test casing, separators and regional forms.
2. Replace inconsistent ISO-wide and Apple-to-Russian source selectors with the same six-language list. Apple translation availability is a capability check, not an import eligibility check.
3. Persist the last chosen new-book language, separately from the active Dictionary/Practice filter. Use Polish only as the backwards-compatible initial preference; show the choice for confirmation. Supported manifest language takes precedence over that preference.
4. Pass language explicitly through new-book preparation and entry creation. Retain model decoding/default behavior necessary for existing stores. Do not bulk rewrite old entries to the currently selected language.
5. Reject unsupported language in new packages with an actionable message. Existing books/backups outside the six-language scope remain readable and retain their metadata: allow existing-language groups when necessary to avoid hiding historical entries, without advertising new-book support for those languages.
6. Keep the existing source-language history lock. Before that lock, changing a book's language must consistently update linked entries and invalidate affected generated analyses/translations/indexes using existing rollback patterns. A dropdown filter change never edits data.

## 2. Dictionary and language-scoped queries

Primary files: `App/Views/DictionaryView.swift`, `App/Models/LibraryModels.swift`, dictionary save/transfer services, app state/settings owner.

1. Implement a shared persisted active-source selection. Default to an available data language when possible, otherwise the initial preference. Retain a user's selection even when its current group becomes empty.
2. Add a clearly labelled language dropdown to Dictionary and Practice. Use the same source and state, and keep language visible during preparation and review.
3. Centralize language scoping before applying query, level and readiness filters. Scope counts and empty-state messages using the same candidate base; do not display global totals beside a filtered list.
4. Audit identity/deduplication/merge paths. Equal text in different languages must not collide; UUID-based conflict handling must still detect a language mismatch. Preserve separate phrase contexts where existing semantics require it.
5. Preserve Russian target checks and labels. Source grouping must use the entry's persisted language, not its currently linked book or active UI setting.

## 3. Practice and checkpoint isolation

Primary files: `App/Views/PracticeHomeView.swift`, `App/Views/LearningSessionView.swift`, `App/Models/LearningRoundState.swift`, checkpoint persistence and backup services.

1. Apply the active source filter to setup, eligible counts, quick start, preview, retry queues and learnt-entry review. Preserve cooldown, level, undo and promotion rules.
2. Bind every new round/checkpoint to its source language. Validate all entry IDs against that language when starting/resuming and before applying progress changes.
3. An active round keeps its original language even if shared screen selection changes. Results remain scoped to that round.
4. Maintain independent unfinished checkpoints per language so switching languages does not overwrite another language's progress. Resume the selected language's checkpoint.
5. Decode legacy checkpoints conservatively: infer the language only if all referenced entries resolve to one source language. Do not resume a mixed/invalid legacy checkpoint; discard only that checkpoint with clear recovery behavior, preserving all saved card levels.
6. Update backup/restore to round-trip all language checkpoints with backward-compatible optional fields or a deliberate versioned decoder. Validate each checkpoint and remap references as required by existing restore semantics.

## 4. Reading vocabulary, counting and caches

Primary files: `App/Services/ReadingVocabularyStore.swift`, `App/Services/VocabularyIndex.swift`, `App/Services/VocabularyTextIndex.swift`, `App/Services/VocabularyTokenizer.swift`, import previews and reading models.

1. Audit every vocabulary read/write, completion event, import preview, highlight and book counter for source-language isolation. Complete a Polish book without affecting English book counts; share knowledge across two Polish books.
2. Include canonical language in any cache whose result depends on language. Changing a book language must not reuse stale results. Retain parser/tokenizer versioning.
3. Establish regression fixtures for apostrophes (`l’homme`, `l'amico`), hyphens, accented characters, German umlauts/ß, decomposed Unicode, punctuation and repeated forms across languages.
4. Do not change persisted token semantics gratuitously. If fixes require a tokenizer-version change, implement migration/compatibility for reading batches and dictionary v3 backups; the current exact-version guard must not strand older exports. Rebuild disposable indexes without deleting learned history.

## 5. Context analysis and word explanations

Primary files: `App/Models/ContextAnalysis.swift`, `App/Models/WordExplanation.swift`, `App/Services/ContextualTranslationCoordinator.swift`, `App/Services/OpenAIContextAnalysisProvider.swift`, `App/Services/OpenAIWordExplanationProvider.swift`.

1. Add Italian function-word handling and review the five existing supported-language lists. Replace Polish-only examples in the mandatory prompt with neutral wording. Version changed prompts appropriately; preserve user custom prompts.
2. Ensure source language comes from the selection/book or saved entry throughout request construction, validation and cache identity; Russian remains the target.
3. Pass source-language hints into system tokenization where appropriate. Verify selection ranges, punctuation, context extraction and reconstruction of explanation rows agree for the six languages.
4. Preserve UTF-16 ranges and exact source text. A lexical token and a whitespace timing unit need not be identical; do not force a timing-format migration unless a demonstrated supported-language defect requires it.
5. Keep historical Polish dictionary result/diagnostic fields readable and exportable.

## 6. Local alignment and backend

Primary paths: `tools/subtitle-aligner/`, `backend/alignment/`, `infra/alignment/`, `docs/ALIGNMENT_BENCHMARKS.md`, backend architecture/API docs.

1. Expand backend accepted language values from only `pl` to exactly the six supported base codes. Update `domain.py`, OpenAPI schema and all affected contract/infrastructure assertions together. Explicitly validate accepted/rejected codes and casing policy.
2. Trace language end to end through request validation, stored job data, worker/model invocation, retries, finalization, reports and output manifests. Never fall back to Polish when a language was supplied; ensure reuse/idempotency identities distinguish language where applicable.
3. Align local CLI/batch language validation with the supported scope. Keep manifest-vs-CLI mismatch checks. Make single-file language selection explicit or clearly reported; avoid undocumented default-language behavior. Test each supported code and rejection of unsupported codes.
4. Check selected alignment models/profiles can accept multilingual input; disallow English-only models for non-English jobs where relevant. Keep existing quotas, admission controls, temporary storage, auth capabilities and timeout limits unchanged.
5. Test text/timing reconstruction for apostrophes and punctuation across the six languages. Preserve current package and word-timing formats unless evidence requires versioning; test old-package loading if changed.
6. Run existing backend/infra/local-tool checks and add a six-language contract matrix. Separate mocked pipeline correctness from measured alignment quality.
7. Define a reproducible real-audio benchmark matrix for all six languages, recording model/profile, fixture provenance, failures, untimed coverage and manual listening findings. Run available fixtures without inventing results or incurring unapproved cloud deployments. Explicitly list any unexecuted language quality benchmarks as release limitations; keep the existing deployment gate.

## 7. Backup and compatibility

Primary files: `App/Services/DictionaryTransferService.swift`, `App/Services/LibraryBackupService.swift`, `docs/dictionary.schema.json`, backup docs.

1. Preserve source language for books, entries and reading forms through all merge/restore modes. Never use the UI filter to infer imported entry language.
2. Add active-language/new-book preferences to the typed backup settings allowlist if consistent with the existing portable-settings contract. Older files lacking these preferences retain sensible local defaults.
3. Support per-language checkpoints from section 3 and legacy one-checkpoint imports. Preview/revalidation/rollback must remain atomic under existing guarantees.
4. Cover backup round trips with identical word spellings in two languages, entries whose books were deleted, regional tags, legacy Polish records and unrelated local data.

## Acceptance matrix

- Two books (`en`, `pl`), ten entries each: Dictionary shows ten in either selection; Practice offers only that group's eligible entries. Search, level counts, readiness, quick start and learnt review never leak another language.
- Progress, retries and unfinished sessions survive switching languages, restart and backup/restore independently.
- Two same-language books share reading knowledge; a different-language book with the same spelling is unaffected. Deleting a source book preserves dictionary and studied-word language.
- All six languages import through supported workflows, produce requests with correct source and `ru` target, and retain correct source after saving and restoring.
- Changing the language filter causes no mutation of book/entry language, generated translations or saved levels.
- Unsupported Apple pair/download state does not block reading; unsupported new-package language is explicit.
- Backend accepts all six languages, rejects unsupported values and preserves language through the pipeline; existing limits and authorization tests still pass.
- Old stores, dictionary/library backups and word-timing packages remain usable. Legacy mixed checkpoints cannot create mixed-language practice.
- UI verification covers dropdown synchronization and empty groups on iPhone/iPad; use meaningful unit/integration tests for data scoping and migration, not implementation-mirroring tests.

## Delivery sequence and evidence

1. Inspect applicable repository instructions and existing persistence/checkpoint architecture before coding.
2. Implement registry/import and shared filter; then dictionary/practice/checkpoints and compatibility.
3. Verify vocabulary/cache isolation and language-specific text analysis.
4. Implement backend/local-tool contracts and checks.
5. Run relevant Swift tests/build, Python suites and infra assertions using repository tooling. Record actual commands/results and limitations; do not label unavailable runtime/real-audio checks as passed.
6. Update `knowledgebase/CHANGELOG.md`, `DECISIONS.md`, `PROJECT.md` and affected operational/schema documentation in the same implementation PR. Distinguish implemented behavior from pending benchmarks.
7. Review diff for cross-language data loss or leakage, commit and create a reviewable PR when repository access permits. Attach any created PR to the chat. Do not merge or deploy.

## Implementation evidence (2026-10-27)

Implemented the shared source registry and separate import/active preferences; language-scoped dictionary/practice pools and frozen session language; per-language checkpoints with legacy recovery; additive library backup rounds/preferences and language-aware book matching; regional reading-history grouping without a tokenizer migration; Italian function words and mandatory prompt v5; source hints for system word tokenization; and the six-code backend/local alignment contract.

Verification used Xcode 26.6 / iOS Simulator 26.5:

- `xcodebuild test ... -only-testing:ForeignLanguageLearnerTests -only-testing:ForeignLanguageLearnerUITests/NativeDesignFlowTests/testSourceLanguagePickerSynchronizesDictionaryPracticeAndEmptyGroups CODE_SIGNING_ALLOWED=NO`: 204 unit tests and the new UI check pass on iPhone 17 Pro Max and iPad Pro 13-inch (M5). The final iPad run also checks pure checkpoint queries and unreadable-checkpoint recovery. The full older UI suite was interrupted during development and is not claimed as completed.
- `xcodebuild build ... -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`: unsigned Release build passes.
- `python3 -m unittest discover -s backend -p 'test_*.py'`: 15 pass, including six-code API/OpenAPI parity, stored worker language, idempotency conflicts and finalization mismatch rejection.
- `python3 -m unittest discover -s tools/subtitle-aligner -p 'test_*.py'`: 26 pass, including six-language mocked batch output/report propagation and punctuation reconstruction.
- `PYTHONPATH=tools/subtitle-aligner python3 -m unittest worker.test_worker`: 3 pass.
- `npm ci --ignore-scripts` followed by `npm test` in `infra/alignment`: TypeScript build and CDK assertions pass.
- `git diff --check`: passes.

Limits: No matching real-audio/model fixtures were present, so every row of the six-language real-audio quality matrix remains unexecuted. No paid cloud/model call, cloud deployment or merge was performed. Existing historical Polish diagnostics, unrelated legacy languages, tokenizer-v1 reading batches, dictionary v1/v2/v3 files and package/timing formats remain supported through existing decoders and regression suites.
