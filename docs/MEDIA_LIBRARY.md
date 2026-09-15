# Media library

The app uses **transcript segment** for a timed subtitle passage throughout the implementation.

## Use

1. Choose **Upload item** from the Library.
2. Select playable audio (or video) and a UTF-8 SRT, WebVTT, or TXT file.
3. Choose **Import**. Both files are copied into Application Support; no server is required.
4. Open the item. Use the bottom controls to play, pause, skip ten seconds, or seek.
5. Long-press transcript text and extend the native selection handles across words or paragraphs, including by dragging toward the scrolling edge. Choose **Add to Dictionary**.
6. Open **Dictionary** from the Library to see saved phrases. Swipe to delete an entry.

SRT/WebVTT segments drive highlighting and automatic scrolling. Plain text remains selectable but has no synchronization. Manual scrolling or text selection suspends following; **Follow audio** resumes it after selection is dismissed. Continuous text allows selection across subtitle boundaries without changing pages.

## Structure

- SwiftData stores learning items, transcript segments, resume positions, and dictionary entries.
- `MediaImportService` copies security-scoped files, parses transcripts, validates AVFoundation playback, and cleans up failed imports.
- `TranscriptParser` handles SRT and WebVTT timestamps, optional identifiers/settings, basic markup, and plain text. Invalid segments fail import with an error. Transcript size is capped at 10 MB. Styling and positioning metadata are intentionally flattened into readable text.
- `TranscriptDocument` maps UTF-16 ranges to segment indexes and looks up the most recently started segment by playback time. For overlapping segments, that segment takes precedence until it ends; gaps have no highlight.
- `PlaybackController` owns AVPlayer and a 200 ms time observer. The reader releases it when dismissed.
- `TranscriptTextView` bridges UITextView for native selection and the dictionary edit-menu action. Highlight changes preserve the text and selection.
- Video uses the same storage, player, and transcript model, with a video region above the transcript.

Media stays local. Lock-screen controls, background playback, cloud sync, translations, automatic alignment of untimed text, and library-item deletion are future work.

## Validation

Run `bash scripts/test.sh` once the Xcode iOS platform and simulator runtime are installed. CI runs unit/UI tests and a Release device build. Unit tests cover parsing, timing boundaries, Unicode ranges, backward seeking, overlap policy, and dictionary persistence. UI tests cover the initial library, import sheet, and dictionary navigation.

Before release, manually verify with a long transcript on iPhone and iPad: selection across paragraphs and while dragging at screen edges, VoiceOver, large Dynamic Type sizes, seeking while paused/playing, file-provider downloads, unsupported media, app relaunch/resume, and audio interruptions. These device interactions are not established by parser unit tests.
