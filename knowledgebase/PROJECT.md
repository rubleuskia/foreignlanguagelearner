# Foreign Language Learner

## Standalone listening practice

Practice also includes an independent listening exercise: up to ten random audio-backed dictionary phrases in the active language, audio plus five target-language translations, and immediate feedback. Existing cloud configuration generates the choices from the phrase and language pair alone. This exercise does not track progress or affect vocabulary levels and regular training sessions.


## Supported source-language workflow

New books may use English, French, Spanish, German, Italian or Polish, with Russian translations and explanations. Import confirms a separately remembered book language; supported package metadata takes precedence. Reading is available without an Apple translation pair. Historical books/backup languages outside this list remain readable and appear as existing dictionary/practice groups.

Dictionary and Practice share one remembered source-language selection. Its flag-labelled dropdown offers only languages represented by books in the library; when all books share one language, the flag and name remain visible without a dropdown. With no books, saved entry languages remain available. Counts, levels, eligible phrases, quick starts, learnt reviews and resumable rounds stay within that language. Each saved entry retains its own source language after its book is deleted. Reading knowledge is shared across books in the same canonical language and isolated across languages; dictionary phrases and reading forms remain separate metrics. Library backup carries all independent unfinished rounds and language preferences.

Local and backend alignment accept the six lowercase source codes. Deployment remains gated on measured task limits and the six-language real-audio benchmark matrix; no deployment accompanies this change.


## Purpose

Foreign Language Learner is a native SwiftUI iPhone and iPad application for learning from spoken content. A learner imports local audio or video, or a ZIP containing a multi-track audiobook, reads matching full text and available per-track subtitles, selects words or phrases, saves them to a personal dictionary, and practices them later.

The project also contains a standalone local subtitle-aligner utility. It extracts reviewable UTF-8 sections from EPUB when needed, converts matching text and narration into timed SRT/WebVTT files and can batch an explicitly mapped multi-track book into an importable package.

## Current scope

The ⋯ menu offers a saved choice between book pages and vertical scrolling in both readers, retaining the reading position when switching.

Reading controls automatically choose synchronized track text or full text. The ⋯ menu contains the saved New words highlighting setting; the reading canvas omits vocabulary statistics and the player omits the completion percentage to preserve text space.

Native page transitions retain neighboring pages throughout swipes. Timed audio phrases stay whole on one page; an oversized phrase has its own vertically scrollable page. Follow audio is available in the fixed bottom reader footer.

Both readers present book pages with horizontal page turns and text wrapped to the viewport. Timed subtitle breaks are reflowed into continuous prose; untimed text preserves paragraphs. Font and viewport changes repaginate around the current reading position, and audio following selects the active cue's page.

The interface defaults to Russian and can be switched to English in Settings without changing the language of a book or dictionary entry. The chosen interface language is saved locally and included in library-state backups.


- Progressive book onboarding: a unified import wizard accepts TXT-only, audio-only, raw audio ZIPs with optional external TXT, or complete packages. Books can be supplemented or updated through their resource menu with journaled file publication and database rollback. Unsynchronized books open full text directly; text position is independent of audio position. Contextual tutorial popovers, a guide, an isolated tutorial reset and a locally narrated original example support first use.

- Image-led dark Library with blue controls and green progress, title search, reading filters and recent/title sorting. Opening a book shows an overview, read/new/studied word and saved-phrase statistics, and chapter/part progress before entering the reader. Continue preserves saved positions; chapter images inherit one book cover. Import accepts an uploaded image, a `cover` image in ZIP or one of six small bundled offline covers.

- Native Library / Dictionary / Practice navigation, a dedicated practice home and a featured unfinished book chosen by the most recent Play tap; shared native action hierarchy with Liquid Glass on iOS 26 and iOS 18 fallbacks. Both readers use scalable editorial serif typography and a comfortable iPad text measure, with floating playback controls and disclosed reading options.

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
- Local Activity dashboard with day/week/month views, language-scoped reading-word counts, distinct phrase advancements and level-4 completions, reading/listening wall time, charts, monthly activity calendar, current streak and recent transitions. Phrase/time history starts with the update, survives source deletion and is included in library-state backups; reading words reuse their existing first-learned dates. Statistics reuse a persistent derived snapshot and prepared reports; pull down from the top of Activity to refresh explicitly. A missing cache is built once, and the last-update timestamp remains visible.
- XcodeGen project generation, XCTest unit/UI coverage, GitHub Actions CI, and manually triggered signed publishing.
- Local subtitle alignment with normal and guided modes, diagnostics, review flags, SRT/WebVTT output, and manifest-driven sequential audiobook batch/rerun support.
- An undeployed AWS implementation for optional temporary audio + TXT alignment jobs, with a public
  test contract, per-job bearer capabilities, strict global admission limits and a 60-minute ceiling.

## Boundaries

The shipped app has no project-operated backend endpoint or analytics. Media, saved dictionary data and reading vocabulary remain local unless the user explicitly exports a dictionary file. Ordinary Apple Translation uses installed on-device language models for explicit translation, legacy pending recovery and untranslated imports. Contextual translation is an opt-in cloud feature: the app sends only the selected phrase and bounded surrounding text directly to OpenAI with a user-provided key stored in Keychain; billing and quotas belong to that user's OpenAI account. The app no longer ships the unreachable Wiktionary lookup or its exclusive SGJP morphology pack. Existing cached definitions and historical diagnostics remain readable and exportable; contextual lemmas use the existing OpenAI analysis. The repository's cloud alignment backend has not been deployed or connected to iOS; its benchmark and explicit deployment gate must pass before public testing. Cloud sync, lock-screen controls, in-app alignment, arbitrary track editing after import, automatic TXT chapter detection, and gapless playback remain future work or are not yet established as shipped behavior. The resource menu supports replacing the complete audio set; synchronization attachment verifies current recordings rather than generating alignment.

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


Audiobook chapters are marked read automatically at natural playback completion using the same studied-vocabulary update as manual completion. The in-reader chapter chooser restarts at the beginning and resets transcript scrolling; chapter rows in the book overview resume that chapter’s saved position. Automatic dictionary audio includes up to half a second of context on each side; saved manual boundaries remain exact. The boundary editor supports two timeline handles with 0.1-second precision. Active audio playback keeps the screen awake for reading along.
