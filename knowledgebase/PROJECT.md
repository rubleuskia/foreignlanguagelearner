# Foreign Language Learner

## Purpose

Foreign Language Learner is a native SwiftUI iPhone and iPad application for learning from spoken content. A learner imports local audio or video, or a ZIP containing a multi-track audiobook, reads matching full text and available per-track subtitles, selects words or phrases, saves them to a personal dictionary, and practices them later.

The project also contains a standalone local subtitle-aligner utility. It converts matching UTF-8 text and narration into timed SRT/WebVTT files and can batch an explicitly mapped multi-track book into an importable package.

## Current scope

- iOS 18+; Swift 6; SwiftUI; iPhone and iPad.
- Local media library backed by SwiftData and Application Support files.
- Previewed raw ZIP and strict manifest-package audiobook import with 1–100 physical audio tracks, sequential/background audio playback, per-track seeking and timers, local progress, and crash recovery.
- Audio and video playback with timed SRT/WebVTT transcript highlighting.
- Plain TXT import for selectable, untimed text, including full-book reading that never invents track boundaries.
- Native transcript selection and dictionary capture.
- Dictionary and learning workflows, including versioned JSON backups and previewed dictionary restoration with contextual analysis, notes and audio-source metadata, OpenAI contextual previews with explicit dictionary saving and concise word/lemma/meaning breakdowns, level-aware pre-learning card review followed by resumable fixed-size retrying practice rounds with immediate per-answer level saves and dictionary level filters, global learned-phrase review, phrase audio and session-local playback speed, a source-first detail card with inline playback followed by translation and Meaning in context. Legacy word-help and Polish definition data/services remain stored but are no longer exposed on the detail card.
- Color-coded dictionary progress and local diagnostic-log export from settings and translation details.
- XcodeGen project generation, XCTest unit/UI coverage, GitHub Actions CI, and manually triggered signed publishing.
- Local subtitle alignment with normal and guided modes, diagnostics, review flags, SRT/WebVTT output, and manifest-driven sequential audiobook batch/rerun support.
- An undeployed AWS implementation for optional temporary audio + TXT alignment jobs, with a public
  test contract, per-job bearer capabilities, strict global admission limits and a 60-minute ceiling.

## Boundaries

The shipped app has no project-operated backend endpoint or analytics. Media and saved dictionary data remain local unless the user explicitly exports a dictionary file. Ordinary Apple Translation uses installed on-device language models; the legacy word-by-word service remains in code without a detail-card action. Contextual translation is an opt-in cloud feature: the app sends only the selected phrase and bounded surrounding text directly to OpenAI with a user-provided key stored in Keychain; billing and quotas belong to that user's OpenAI account. Polish inflected-form analysis uses a bundled SGJP-derived database entirely on device; the retained definition service contacts the public Polish Wiktionary API only on explicit lookup and caches successful results; the simplified detail card no longer exposes this action. The repository's cloud alignment backend has not been deployed or connected to iOS; its benchmark and explicit deployment gate must pass before public testing. Cloud sync, lock-screen controls, in-app alignment, track editing/replacement after import, automatic TXT chapter detection, gapless playback, and library-item deletion remain future work or are not yet established as shipped behavior.

## Repository map

- `App/` — SwiftUI UI, SwiftData models, playback, import, transcript, dictionary, and learning services.
- `Tests/` — unit and UI tests.
- `tools/subtitle-aligner/` — local TXT + audio alignment utility.
- `backend/alignment/` — cloud alignment domain logic, Lambda handlers and OpenAPI contract.
- `infra/alignment/` — AWS CDK stack and infrastructure assertions for the undeployed test backend.
- `tools/polish-lemma-importer/` — reproducible SGJP-to-SQLite morphology-pack builder.
- `docs/` — detailed operational and feature documentation.
- `project.yml` — XcodeGen source of truth.
- `.github/workflows/` and `fastlane/` — CI and release automation.

## Development principles

Prefer local-first, reversible, testable changes. Keep generated Xcode output and personal media out of source control. Treat timing, Unicode/UTF-16 selection ranges, file-provider imports, and accessibility as correctness concerns, not presentation details.
