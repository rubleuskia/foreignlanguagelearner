# Foreign Language Learner

## Purpose

Foreign Language Learner is a native SwiftUI iPhone and iPad application for learning from spoken content. A learner imports local audio or video with a matching transcript, follows synchronized text while listening, selects words or phrases, saves them to a personal dictionary, and practices them later.

The project also contains a standalone local subtitle-aligner utility. It converts matching UTF-8 text and narration into timed SRT/WebVTT files that the app can import.

## Current scope

- iOS 17+; Swift 6; SwiftUI; iPhone and iPad.
- Local media library backed by SwiftData and Application Support files.
- Audio and video playback with timed SRT/WebVTT transcript highlighting.
- Plain TXT import for selectable, untimed text.
- Native transcript selection and dictionary capture.
- Dictionary and learning-round foundations, including portable JSON transfer, contextual sentence translation, on-demand word help, offline Polish form-to-lemma resolution, cached Polish Wiktionary definitions, and translation-oriented workflows.
- XcodeGen project generation, XCTest unit/UI coverage, GitHub Actions CI, and manually triggered signed publishing.
- Local subtitle alignment with normal and guided modes, diagnostics, review flags, and SRT/WebVTT output.

## Boundaries

The app has no backend or analytics. Media and saved dictionary data remain local unless the user explicitly exports a dictionary file. Apple Translation uses installed on-device language models. Polish inflected-form analysis uses a bundled SGJP-derived database entirely on device; definition lookup then contacts the public Polish Wiktionary API only after an explicit per-word action and caches successful results for later offline use. Cloud sync, lock-screen controls, background playback, automatic alignment inside the app, and library-item deletion remain future work or are not yet established as shipped behavior.

## Repository map

- `App/` — SwiftUI UI, SwiftData models, playback, import, transcript, dictionary, and learning services.
- `Tests/` — unit and UI tests.
- `tools/subtitle-aligner/` — local TXT + audio alignment utility.
- `tools/polish-lemma-importer/` — reproducible SGJP-to-SQLite morphology-pack builder.
- `docs/` — detailed operational and feature documentation.
- `project.yml` — XcodeGen source of truth.
- `.github/workflows/` and `fastlane/` — CI and release automation.

## Development principles

Prefer local-first, reversible, testable changes. Keep generated Xcode output and personal media out of source control. Treat timing, Unicode/UTF-16 selection ranges, file-provider imports, and accessibility as correctness concerns, not presentation details.
