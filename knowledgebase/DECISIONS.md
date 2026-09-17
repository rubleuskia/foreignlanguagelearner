# Architectural and product decisions

## Local-first media and persistence

Media is copied into Application Support and metadata/transcript segments are stored with SwiftData. Imports do not require a server or network access, and failed imports clean up their copied files.

## Timed transcript model

The implementation uses “transcript segment” for a timed subtitle passage. SRT and WebVTT are the synchronized formats; TXT stays selectable but untimed. Highlighting is cue-level rather than word-level, while the subtitle utility preserves word timing in JSON for inspection and future work.

## Native selection

Transcript text is bridged to `UITextView` so learners get native selection handles, edge scrolling, and an edit-menu action for adding a phrase to the dictionary. Continuous text is used so selection can cross subtitle boundaries.

## Follow behavior

Automatic transcript following pauses during manual scrolling or text selection. The learner can resume it with “Follow audio.” Overlapping timed segments use the most recently started segment until it ends; gaps have no highlight.

## Subtitle alignment is a separate tool

Untimed text is aligned outside the app using the local `tools/subtitle-aligner` utility. Guided alignment is available for long recordings with drift; review output can retain zero-duration words but is explicitly flagged rather than pretending timing is accurate.

## Dictionary portability and translation

Dictionary transfer uses readable JSON with stable entry identity, source context, translation metadata, and learning progress. Translation-only imports may update translation content while preserving current progress. The architecture keeps source/target language metadata extensible, with Russian as the initial product need. Apple Translation was selected as the initial on-device integration direction; broader LLM/API integration remains an option for later quality improvements.

Contextual translation remains local and user-triggered. Because Apple Translation has no separate context, dictionary-definition, or grammatical-analysis parameter, the app translates the selected expression and its containing sentence as separate requests and presents both for comparison. Word-by-word help is also explicit and is described as individual translation rather than authoritative semantic or morphological analysis. Existing manual and imported translations are never silently replaced by contextual results. High-fidelity translation is preferred where the OS exposes it, with the compatible standard configuration retained for older supported systems.

Polish monolingual definitions use the public Polish Wiktionary MediaWiki API as an explicit per-word action. The app parses only the Polish-language section, associates numbered examples with numbered meanings, attributes and links the source article, and persists successful results with the existing word-help data for offline reuse. Lookup failures never remove cached content, and automatic/background harvesting is outside the product boundary. The parser is conservative because Wiktionary markup is community-maintained and may evolve.

## Learning parts

Learning content is modeled as virtual parts rather than requiring duplicated media files. This keeps a shared dictionary independent of whether the referenced media exists on another device and supports future practice flows.

## Project and release tooling

`project.yml` is authoritative and the Xcode project is generated. CI and publishing use the macOS 26 runner with Xcode 26.6 so iOS 26 Translation APIs are available consistently. CI runs unit/UI tests and an unsigned Release build. Publishing is manual, gated by tests, uses an ephemeral keychain, and uploads to TestFlight or prepares an App Store draft without automatically submitting or releasing.

## Seek synchronization

Playback seeks use generation tokens and completion callbacks. Periodic time observations are ignored while a seek is active, and stale completions cannot overwrite a newer seek. This addresses the observed 2–4 second transcript drift after manual seeking and previous/next navigation.
