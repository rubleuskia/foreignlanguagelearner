# Project changelog

Entries are ordered oldest to newest and summarize the project history recovered from the repository and Codex task history.

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

## 2026-09-16 — Sentence-based source context

- Limited captured dictionary context to the selected sentence plus the preceding and following sentences.
- Trimmed the adjacent sentences to 15 words each, preserving the selected phrase and reducing oversized context cards.
- No architectural/product decision or project-overview change was required.
