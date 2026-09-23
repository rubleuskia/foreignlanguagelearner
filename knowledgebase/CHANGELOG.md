# Project changelog

## 2026-09-23 — Foundation Models feasibility preparation

- Reviewed and tightened the contextual-analysis implementation plan, making physical-device
  Polish-to-Russian availability and quality evaluation a release gate.
- Added an isolated iOS 26 Foundation Models probe, reusable domain/request-building contracts,
  Unicode/UTF-16 coverage, and a frozen legacy SwiftData store fixture for later migration testing.
- The gate has not been run on an eligible device, so production behavior and the iOS 18 deployment
  target are unchanged. The production target is now iOS 26.0 and includes an isolated provider for
  device testing; the existing contextual UI/workflow remains unchanged. Recorded the planned
  architecture decision; `PROJECT.md` is unchanged.

## 2026-09-23 — Multi-track audiobook import and playback

- Added previewed local ZIP and strict `.book.zip` import for 1–100 audio tracks, generated stable track identities, sequential playback, cross-track global seeking, per-track resume positions, and full-book untimed reading.
- Added manifest-linked per-track SRT/WebVTT reading and dictionary audio references keyed by `(item ID, track ID)` so equal local cue times on different tracks resolve to the correct file. Plain full-text selections remain deliberately untimed.
- Added streamed archive limits and CRC/path/collision checks, staging journals, save rollback, startup recovery, and reversible library deletion so filesystem changes do not masquerade as database transactions.
- Extended the shared selection preview, phrase-audio resolver, playback intent/rate controller, transcript follow behavior, dictionary detail, and learning round UI with track-aware behavior while preserving their existing lifecycle and accessibility contracts.
- Added the strict v1 book JSON schema and a sequential multi-track alignment CLI with full preflight, reports, fail-closed publishing, and fingerprint-checked single-track reruns.
- Recorded the track-local timeline, immutable identity, untimed TXT, legacy adapter, migration, import transaction, and batch publishing decisions. Updated the project overview because multi-track ZIP import and batch alignment are now supported workflows.

## 2026-09-23 — Generated Xcode project troubleshooting

- Documented the stale local Xcode project that omitted `SelectionTranslationPreview.swift`, and its repair through `bash scripts/bootstrap.sh`.
- Added a [prevention and recovery guide](../docs/PREVENTING_GENERATED_PROJECT_DRIFT.md), linked from the README, covering regeneration triggers, build/test commands, CI generation, and safe handling of merge conflicts and concurrent edits.
- The local unsigned Debug simulator build succeeded after regeneration; no Swift source change was required. This guide documents the existing XcodeGen workflow, with no new automated enforcement. Architectural/product decisions and the project overview in `DECISIONS.md` and `PROJECT.md` are unchanged.

## 2026-09-22 — Learning and playback UX

- Changed Translate in Context in the reader to an ephemeral preview that translates the phrase and its containing sentence without creating or modifying a dictionary entry.
- Added reliable selection-triggered pause, TextKit-based transcript centering, explicit Follow recovery, and session-local 0.5×–2× playback speed controls.
- Added 5, 10, 20 and all-available learning rounds with a fixed unique starting set, retry-at-end behavior for wrong answers, save-before-advance progress, duplicate-event protection, and explicit skipped-entry accounting.
- Added phrase audio and exact-copy controls across preview, dictionary detail and learning, while keeping original/audio/context hidden until a learning answer is checked.
- Round completion now lists all valid level-4 Russian phrases from current stored data, including phrases learned before the round.
- Updated `PROJECT.md` for the expanded supported learning workflow. Project purpose and system boundaries are unchanged; no persistent preference, transfer-schema, backend or multi-track decision was introduced.

## 2026-09-22 — Cloud alignment backend implementation

- Added an undeployed AWS backend implementation for one audio + matching TXT alignment job: a
  capability-authorized HTTP API, version-pinned multipart uploads, DynamoDB state/idempotency and
  atomic global admission counters, a versioned Standard Step Functions workflow, one CPU Fargate
  worker per accepted start, manifest-gated publication, cancellation, reconciliation and cleanup.
- Preserved public testing without sign-in and the 60-minute hard duration ceiling. Job IDs do not
  grant access; each create request uses a fresh 32-byte client capability, and the service stores
  only its SHA-256 digest. Existing local import and local alignment behavior is unchanged.
- Added an OpenAPI contract, hash-locked Linux/x86_64 CPU worker dependencies, immutable image/model
  build inputs, CDK infrastructure assertions, backend race/validation tests and CI coverage.
- Recorded the benchmark and deployment gate in `docs/ALIGNMENT_BENCHMARKS.md`. No AWS resources were
  deployed, no production pricing or 60-minute benchmark is claimed, and the iOS remote upload/UI
  client remains future implementation work.
- Recorded the temporary-cloud-processing architecture in `DECISIONS.md` and updated `PROJECT.md`
  because the repository now contains an optional backend boundary even though the shipped app
  remains local-first and has no configured service endpoint.

## 2026-09-22 — Reviewed implementation proposals

- Reviewed the AWS alignment, learning UX and multi-track audiobook plans against the current code, resolved contradictory requirements, and added explicit state, timing, persistence, migration and acceptance contracts for implementation.
- Recorded the user-confirmed cloud testing scope: public job creation without sign-in, private per-job access, and recordings up to 60 minutes. Production authentication and broader hardening are deferred to the general [future improvements backlog](../docs/FUTURE_IMPROVEMENTS.md).
- These are implementation proposals, not shipped capabilities. Current architectural decisions and the project overview in `DECISIONS.md` and `PROJECT.md` are unchanged; future implementation PRs must update them when behavior changes.

Entries are ordered oldest to newest and summarize the project history recovered from the repository and Codex task history.

- Fixed Force Translation in the dictionary entry screen so it runs immediately in that screen, shows a translating state instead of “queued,” and explains that the operation may take a moment. No architectural or project-overview decision changed.

## 2026-09-15 — Native iOS foundation

- Created the SwiftUI iPhone/iPad app, XcodeGen specification, unit/UI test targets, simulator CI, and signed publishing workflows.
- Added initial setup, release, signing, and troubleshooting documentation.

## 2026-09-15 — Media transcript library

- Added local audio/video import, SwiftData library models, resume positions, transcript parsing, synchronized playback, native text selection, and phrase dictionary capture.
- Added tests for parsing, timing boundaries, Unicode ranges, backward seeking, overlap policy, dictionary persistence, and core UI flows.

## 2026-09-15 — Subtitle alignment utility

- Added the standalone TXT + audio aligner with SRT/WebVTT export, chapter offsets, guided alignment, validation diagnostics, and review output for untimed words.
- Documented the Polish sample conversion experiments and limitations.

## 2026-09-16 — Virtual learning parts and dictionary roadmap

- Added the virtual learning-parts direction so practice content can be organized without duplicating media.
- Documented translation options, Russian as the initial target, portable dictionary JSON, translation-only imports, conflict handling, and learning-session design.

## 2026-09-16 — Transcript seek synchronization

- Added seek-generation guarding so stale AVPlayer callbacks cannot overwrite a newer requested position.
- Resynchronized the displayed position after the active seek completes; the full local suite passed with 7 unit tests and 2 UI tests in the recorded task.

## 2026-09-16 — Knowledgebase governance

- Added this knowledgebase and `AGENTS.md` rule requiring every completed PR to update project knowledge.

## 2026-09-16 — Translation queue reliability

- Invalidated same-language Apple Translation configurations between dictionary jobs so every queued phrase starts instead of only the first phrase translating.
- Added a Force Translation action to dictionary entry details, with confirmation before replacing an existing translation.
- No architectural/product decision or project-overview change was required.

## 2026-09-16 — Dictionary context visibility

- Added saved source context to dictionary entry details and to the revealed side of learning cards.
- No architectural/product decision or project-overview change was required.

## 2026-09-16 — Contextual translation and sentence help

- Added a Translate in Context transcript action that compares the selected expression with a translation of its containing sentence and highlights the saved selection.
- Added on-demand word-by-word sentence help, with common grammar words hidden by default but available through a reveal toggle.
- Added editable preferred-meaning and personal-note fields, while preserving existing manual or imported translations until the learner explicitly accepts a contextual candidate.
- Translation configurations prefer Apple's high-fidelity strategy on iOS 26.4 and later while retaining the iOS 18-compatible path on earlier systems.
- Moved CI and publishing to the macOS 26 runner with Xcode 26.6 so the iOS 26 Translation APIs compile and are tested consistently.
- Recorded the contextual translation architecture and updated the supported dictionary workflow; no broader project-purpose or boundary change was required.

## 2026-09-16 — Sentence-based source context

- Limited captured dictionary context to the selected sentence plus the preceding and following sentences.
- Trimmed the adjacent sentences to 15 words each, preserving the selected phrase and reducing oversized context cards.
- No architectural/product decision or project-overview change was required.

## 2026-09-17 — Polish Wiktionary definitions

- Added explicit per-word Polish Wiktionary lookup to word-by-word help, with numbered Polish definitions, usage labels, matching examples, source attribution, retry, and refresh states.
- Cached successful Wiktionary results inside saved word-help data so previously viewed definitions remain available offline and survive translation refreshes.
- Added fixture-backed coverage for multilingual article isolation, definition/example parsing, errors, and Polish query encoding.
- Recorded Wiktionary as the first third-party runtime data source and updated the project boundary accordingly; the app still has no backend or analytics.

## 2026-09-17 — Listening and vocabulary market research

- Added [market research](../docs/LANGUAGE_LEARNING_MARKET_RESEARCH.md) comparing LingQ with nine alternatives/workflows, linking user feedback, and prioritizing listening and vocabulary-retention features.
- Mapped proposed features to the current Swift implementation with estimated engineering effort, illustrative budgets, operating-cost assumptions, and a phased validation plan.
- Recommendations are not adopted product or architectural decisions. No project-overview or supported-workflow change was made.
- Перевёл отчёт исследования на русский язык, сохранив структуру, источники, оценки и технические рекомендации.

## 2026-09-17 — Audio playback for saved phrases

- Saved dictionary entries now retain the absolute transcript cue start/end when created from timed media.
- Added a Play/Pause control to dictionary-entry details that reuses the local source media and plays only the saved phrase range.
- Entries imported from JSON, created from untimed text, or whose source media is unavailable continue to work without audio and show an unavailable state.
- Added coverage for source-index preservation and persisted audio ranges. No new architectural decision or project-overview change was required.
- Extended phrase audio to include every subtitle cue touched by a selection and a bounded 0.75-second tail, preventing natural speech from being cut at the first cue boundary.
- Increased the document-picker UI test wait for slower CI simulator launches; no product or architectural decision changed.

## 2026-09-17 — Offline Polish form resolution

- Added a bundled SGJP morphology index containing 4,934,967 Polish surface forms and 5,252,824 unique form-to-lemma pairs.
- Polish Wiktionary lookup now resolves missing inflected forms locally, including `został → zostać`, before requesting the lemma article.
- Added an explicit lemma chooser for ambiguous forms, first-use database installation, SGJP attribution, and a reproducible pack builder.
- Recorded the bundled language-pack architecture and updated the supported dictionary workflow and repository map.

## 2026-09-18 — Reading and review refinements

- Fixed transcript content and highlight synchronization when switching between virtual audiobook parts.
- Expanded partial transcript selections to complete word boundaries before saving or translating them, while preserving the exact selected range in context.
- Added compact phrase translations to dictionary rows.
- Learning cards now highlight the saved phrase in source context and allow the Russian translation to be edited directly.
- Wrong learning answers now return to the end of the current queue, and the round continues until every queued entry is answered correctly.
- Polish Definition failures are now written to the iOS unified log and to a bounded, protected local diagnostic file; the existing dictionary export includes that log and environment metadata for support.
- Recorded the local diagnostic-retention/export decision; no project-overview change was required.
