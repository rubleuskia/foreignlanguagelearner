# Project changelog

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
