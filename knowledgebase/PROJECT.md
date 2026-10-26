# Foreign Language Learner

## Purpose

Foreign Language Learner is a native SwiftUI iPhone and iPad application for learning from spoken content. A learner imports local audio or video, or a ZIP containing a multi-track audiobook, reads matching full text and available per-track subtitles, selects words or phrases, saves them to a personal dictionary, and practices them later.

The project also contains a standalone local subtitle-aligner utility. It converts matching UTF-8 text and narration into timed SRT/WebVTT files and can batch an explicitly mapped multi-track book into an importable package.

## Current scope

- Native Library / Dictionary / Practice navigation, a dedicated practice home and a featured in-progress book; shared native action hierarchy with Liquid Glass on iOS 26 and iOS 18 fallbacks. Both readers use scalable editorial serif typography and a comfortable iPad text measure, with floating playback controls and disclosed reading options.

- iOS 18+; Swift 6; SwiftUI; iPhone and iPad.
- Local media library backed by SwiftData and Application Support files. Library offers portable state backups without book assets: reimport matching books on a new phone, then restore dictionary/reading and training progress, playback positions, settings and prompts, reconnecting phrase audio to the new local books. API credentials remain device-local.
- Previewed raw ZIP and strict manifest-package audiobook import with 1–100 physical audio tracks, sequential/background audio playback, per-track seeking and timers, local progress, and crash recovery.
- Audio and video playback with timed SRT/WebVTT transcript highlighting.
- Plain TXT import for selectable, untimed text, including full-book reading that never invents track boundaries.
- Native transcript selection and dictionary capture, with paint-only word/cue highlighting and a stable chapter/part chooser that can be scrolled while playback continues.
- Confirmed irreversible chapter/whole-book reading, accumulated language-scoped studied word forms, new-word counts in both import workflows and library rows (total unique forms for completed books), and optional viewport-based new-word highlighting in both readers. A persistent derived index caches source vocabularies and updates book counts through word memberships. Reading knowledge is independent of dictionary learning levels, survives library deletion, and is portable in dictionary JSON v3 without media.
- Dictionary and learning workflows, including versioned JSON backups and previewed dictionary restoration with contextual analysis, notes and audio-source metadata, OpenAI contextual previews with explicit dictionary saving and concise word/lemma/meaning breakdowns, level-aware pre-learning card review followed by resumable practice rounds restricted to the lowest eligible level, preview Skip without level changes, swipe answers with a three-second undo and retrying wrong answers with immediate per-answer level saves and dictionary level filters, global learned-phrase review, word-level phrase audio from validated optional timing sidecars, context playback when word timings are unavailable, existing-book phrase-audio updates, and session-local playback speed, a source-first detail card with inline playback followed by translation and Meaning in context. Legacy word-help and Polish definition data remain portable in backups; their unused lookup and translation services have been removed.
- On-demand inline word explanations in contextual previews, dictionary details and learning: simple definitions, contextual meaning and 1–2 complete example sentences in independent situations, with a separate editable prompt, with a bounded local derived cache.
- Color-coded dictionary progress and local diagnostic-log export from settings and translation details.
- XcodeGen project generation, XCTest unit/UI coverage, GitHub Actions CI, and manually triggered signed publishing.
- Local subtitle alignment with normal and guided modes, diagnostics, review flags, SRT/WebVTT output, and manifest-driven sequential audiobook batch/rerun support.
- An undeployed AWS implementation for optional temporary audio + TXT alignment jobs, with a public
  test contract, per-job bearer capabilities, strict global admission limits and a 60-minute ceiling.

## Boundaries

The shipped app has no project-operated backend endpoint or analytics. Media, saved dictionary data and reading vocabulary remain local unless the user explicitly exports a dictionary file. Ordinary Apple Translation uses installed on-device language models for explicit translation, legacy pending recovery and untranslated imports. Contextual translation is an opt-in cloud feature: the app sends only the selected phrase and bounded surrounding text directly to OpenAI with a user-provided key stored in Keychain; billing and quotas belong to that user's OpenAI account. The app no longer ships the unreachable Wiktionary lookup or its exclusive SGJP morphology pack. Existing cached definitions and historical diagnostics remain readable and exportable; contextual lemmas use the existing OpenAI analysis. The repository's cloud alignment backend has not been deployed or connected to iOS; its benchmark and explicit deployment gate must pass before public testing. Cloud sync, lock-screen controls, in-app alignment, track editing/replacement after import, automatic TXT chapter detection, and gapless playback remain future work or are not yet established as shipped behavior.

## Repository map

- `App/` — SwiftUI UI, SwiftData models, playback, import, transcript, dictionary, and learning services.
- `Tests/` — unit and UI tests.
- `tools/subtitle-aligner/` — local TXT + audio alignment utility.
- `backend/alignment/` — cloud alignment domain logic, Lambda handlers and OpenAPI contract.
- `infra/alignment/` — AWS CDK stack and infrastructure assertions for the undeployed test backend.
- `docs/` — detailed operational and feature documentation.
- `project.yml` — XcodeGen source of truth.
- `.github/workflows/` and `fastlane/` — CI and release automation.

## Development principles

Prefer local-first, reversible, testable changes. Keep generated Xcode output and personal media out of source control. Treat timing, Unicode/UTF-16 selection ranges, file-provider imports, and accessibility as correctness concerns, not presentation details.

Practice rounds respect configurable phrase cooldowns after level changes (defaults: level 1 = 24 hours, level 2 = 72 hours, level 3 = 96 hours). Practice → Practice settings edits global intervals with an explicit Save cooldowns action; the start screen can ignore cooldown for a session. Retries within an active round remain available.

Saved phrase audio boundaries can be adjusted locally from dictionary and learning cards through the audio button's context menu, previewed, saved, or reset to automatic timing. Manual ranges survive alignment updates and dictionary backup/restore.

The dictionary shows ready-to-repeat counts per level and a readiness filter that combines with level selection. Quick start opens a preview of up to 10 ready phrases without setup. Round results highlight each phrase’s starting → current learning level alongside the existing learnt-phrase review.


New timed selections offer selected-word and whole-phrase audio modes with independent editable boundaries; legacy entries keep their existing playback. Round results are limited to that round, and four wrong attempts on an entry prevent promotion on its eventual correct answer. Settings supports an explicit API-key/model check. Library and book-reader completion percentages weight completed chapters by audio duration, independently of playback position.


Audiobook chapters are marked read automatically at natural playback completion using the same studied-vocabulary update as manual completion. Explicit chapter selection restarts at the beginning and resets transcript scrolling. Automatic dictionary audio includes up to half a second of context on each side; saved manual boundaries remain exact. The boundary editor supports two timeline handles with 0.1-second precision. Active audio playback keeps the screen awake for reading along.
