# Architectural and product decisions

## Local-first media and persistence

Media is copied into Application Support and metadata/transcript segments are stored with SwiftData. Imports do not require a server or network access, and failed imports clean up their copied files.

Multi-track books use an additive Codable `LearningTrack` array on `LearningItem`. Track IDs are immutable within an imported book and source identity is `(local item UUID, track ID)`. Legacy items remain single-file records exposed through a synthetic `legacy` track adapter; virtual `LearningPart` ranges remain a legacy single-file concept. Additive store compatibility is verified with persistent reopen coverage, and storage failures never fall back to an empty store.

Archive and database changes use a staged transaction protocol with a durable journal. A generated book directory is renamed into the library before the complete SwiftData item is saved; failed saves remove the inserted model and moved directory. Startup recovery derives every path from validated UUIDs. Deletion first moves files into a transaction-specific trash directory, then saves the database deletion, restoring files if that save fails.

## Timed transcript model

The implementation uses “transcript segment” for a timed subtitle passage. SRT and WebVTT are the synchronized formats; TXT stays selectable but untimed. Highlighting is cue-level rather than word-level, while the subtitle utility preserves word timing in JSON for inspection and future work.

Audiobook subtitle times are always local to one physical track. Global playback time is calculated from unrounded verified track durations with half-open track intervals; editable offsets are not stored. Full-book TXT has no inferred audio boundaries. Timed selection stores local cue bounds only when it also stores a `sourceTrackID`; a missing track ID on a multi-track source makes phrase audio unavailable rather than guessing the first track.

## Native selection

Transcript text is bridged to `UITextView` so learners get native selection handles, edge scrolling, and an edit-menu action for adding a phrase to the dictionary. Continuous text is used so selection can cross subtitle boundaries.

## Follow behavior

Automatic transcript following pauses during manual scrolling or text selection. The learner can resume it with “Follow audio.” Overlapping timed segments use the most recently started segment until it ends; gaps have no highlight.

Follow centers the first visual line of the active cue using TextKit 1 after layout. A user-created nonempty selection pauses playback once and disables follow; moving selection handles does not repeat the pause. Explicit Follow clears the selection and recenters without starting playback. Document identity includes cue ranges and source mappings so equal transcript text with changed timing cannot reuse stale highlight or scroll state.

## Subtitle alignment is a separate tool

Untimed text is aligned outside the app using the local `tools/subtitle-aligner` utility. Guided alignment is available for long recordings with drift; review output can retain zero-duration words but is explicitly flagged rather than pretending timing is accurate.

Multi-track batch alignment requires explicit contiguous word ranges and a normalized transcript hash. It preflights all tracks before loading one model, processes sequentially, and publishes an importable package only when every track is aligned or explicitly marked for review. Single-track reruns reuse only artifacts whose complete input/configuration fingerprint still matches.

## Multi-track package and playback

Book package v1 is a strict root `manifest.json` plus one UTF-8 TXT and 1–100 referenced audio tracks, with optional manifest-linked per-track SRT/VTT. Unknown fields and unreferenced strict-package files are rejected. Raw ZIP imports use natural path ordering only as an editable preview suggestion; SRT/VTT files in raw archives are never linked by filename similarity.

Sequential book playback owns one single-file player. Cross-track seeks, automatic transitions, and end notifications are guarded by a book generation plus track identity. The selected rate and explicit play intent survive file replacement, while pause during a pending seek prevents late completion from restarting audio. Track decode errors stop on the named track and remain retryable.

## Dictionary portability and translation

Dictionary transfer uses readable JSON with stable entry identity, source context, translation metadata, and learning progress. Translation-only imports may update translation content while preserving current progress. The architecture keeps source/target language metadata extensible, with Russian as the initial product need. Apple Translation was selected as the initial on-device integration direction; broader LLM/API integration remains an option for later quality improvements.

Contextual translation remains local and user-triggered. Because Apple Translation has no separate context, dictionary-definition, or grammatical-analysis parameter, the app translates the selected expression and its containing sentence as separate requests and presents both for comparison. Word-by-word help is also explicit and is described as individual translation rather than authoritative semantic or morphological analysis. Existing manual and imported translations are never silently replaced by contextual results. High-fidelity translation is preferred where the OS exposes it, with the compatible standard configuration retained for older supported systems.

Reader “Translate in Context” uses an ephemeral value snapshot and a coordinator with no SwiftData context. It never creates a dictionary entry and ignores late translation responses after retry or dismissal. Saving remains a separate “Add to Dictionary” action. The preview shows phrase and sentence translations as separate results rather than claiming model-level contextual translation.

Polish monolingual definitions use the public Polish Wiktionary MediaWiki API as an explicit per-word action. The app parses only the Polish-language section, associates numbered examples with numbered meanings, attributes and links the source article, and persists successful results with the existing word-help data for offline reuse. Lookup failures never remove cached content, and automatic/background harvesting is outside the product boundary. The parser is conservative because Wiktionary markup is community-maintained and may evolve.

Polish inflected forms are resolved locally before a fallback Wiktionary request. A reproducible build tool reduces the BSD-licensed SGJP/Morfeusz source feed to unique `surface form → dictionary title` pairs. For the current debugging phase, the complete database is zlib-compressed into the application bundle and expanded into Application Support on first use. Ambiguous forms remain explicit choices for the learner rather than being resolved arbitrarily. A downloadable language pack can replace the bundled resource later without changing the lookup interface.

## Learning parts

Learning content is modeled as virtual parts rather than requiring duplicated media files. This keeps a shared dictionary independent of whether the referenced media exists on another device and supports future practice flows.

## Learning rounds and completion

A learning round snapshots a unique eligible ID set at Start and keeps its original size. A wrong answer moves the same ID to the pending tail; a right answer completes that entry for the round after its learning-level save succeeds. Deleted or newly ineligible entries are skipped without replacement. Presentation IDs make answer events idempotent, and a failed save leaves level, queue, counters and revealed state unchanged.

Round statistics describe attempts and completion inside that round. The completion screen separately queries every stored level-4 Russian entry with a ready, nonempty translation, so it includes phrases learned before the current round.

## Playback intent, speed and phrase sources

Playback keeps user intent separate from `AVPlayer.rate`, which may be zero while seeking or buffering. Pause clears intent so a pending seek cannot restart audio. Playback speed is owned by each controller, starts at 1×, survives pause and media open/close inside that controller, and is not persisted across screens or launches.

Phrase audio resolves only an entry's matching local source item and a finite range within the selected legacy file or exact multi-track track duration. Source identity includes the optional track ID; a multi-track entry without a valid track ID is unavailable rather than falling back to another track. Missing local media remains a text-only experience; the app does not substitute another library item or fetch media from the network.

## Project and release tooling

`project.yml` is authoritative and the Xcode project is generated. CI and publishing use the macOS 26 runner with Xcode 26.6 so iOS 26 Translation APIs are available consistently. CI runs unit/UI tests and an unsigned Release build. Publishing is manual, gated by tests, uses an ephemeral keychain, and uploads to TestFlight or prepares an App Store draft without automatically submitting or releasing.

## Seek synchronization

Playback seeks use generation tokens and completion callbacks. Periodic time observations are ignored while a seek is active, and stale completions cannot overwrite a newer seek. This addresses the observed 2–4 second transcript drift after manual seeking and previous/next navigation.

## Exportable lookup diagnostics

Polish Definition failures are recorded both through Apple's unified `Logger` and in an app-local, file-protected JSON log capped at 200 newest events. Dictionary export embeds a snapshot of these events plus app/OS versions in an optional `diagnostics` field, preserving version-1 import compatibility and requiring an explicit user export before diagnostic data leaves the device. Logs contain the looked-up word and technical error details, but not source sentence context or media content.
