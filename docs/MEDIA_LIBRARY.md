# Media library

The app uses **transcript segment** for a timed subtitle passage throughout the implementation.

## Use

1. Choose **Add book** from Library, then choose TXT, one audio file, audio ZIP with optional separate TXT, or a complete book ZIP. The additional **Audio or video with SRT / VTT subtitles** option retains single-file timed import.
2. Select files and check their contents. TXT must be UTF-8 under 10 MB. Raw audio ZIPs support 1–100 MP3, M4A or WAV tracks; complete synchronized ZIPs use the strict book manifest contract. Check the suggested raw track order before saving.
3. Choose **Add book** after reviewing title, language and composition. Files are copied into Application Support; no server is required. Text-only reading and audio-only listening are supported.
4. Open the item. Use the bottom controls to play, pause, skip ten seconds, or seek.
5. Long-press transcript text and extend the native selection handles across words or paragraphs, including by dragging toward the scrolling edge. Choose **Add to Dictionary**.
6. Open the **Dictionary** tab to see saved phrases and **Practice** to repeat them. Swipe to delete an entry.

Text and audio can be supplemented later through the vertical **⋮** menu on a book row or in either reader. **Replace text** resets its position, completion and dependent synchronization; **Replace audio** replaces the entire audio set and clears old phrase audio links. Card text, translations, learning levels and previously studied forms survive. Replacement previews explain the effects and require explicit confirmation. **Book files** shows the attached resources.

**Add synchronization** accepts a complete package made from the current recordings. Matching uses exact audio hashes in the displayed order and normalized current text; filenames alone are insufficient. Existing track identities and valid manual phrase intervals remain. Timing-only phrase refinements are also still available in the audiobook reader.

Unsynchronized books open full text directly. There is no inferred text-to-track mapping or phrase audio for untimed selections. Full-text reading stores a character anchor separately from audio playback; text-only books use explicit completion rather than a fabricated duration-based percentage.

The empty library offers **Try an example**: original English text with on-device narration and one timed cue, or a readable text fallback when a local voice is unavailable. Settings → **Help and tutorial** provides the guide, tip toggle and tutorial-only reset.

SRT/WebVTT segments drive highlighting and automatic scrolling. Plain text remains selectable but has no synchronization. Manual scrolling or text selection suspends following; **Follow audio** resumes it after selection is dismissed. Continuous text allows selection across subtitle boundaries without changing pages.

## Structure

- SwiftData stores learning items, transcript segments, resume positions, and dictionary entries.
- `MediaImportService` copies security-scoped files, parses transcripts, validates AVFoundation playback, and cleans up failed imports.
- `BookImportService` stages independent text/audio or checked ZIP contents. Partial local books do not weaken the strict external manifest schema.
- `BookResourceUpdateService` publishes uniquely named resource generations and journals the move before updating model references. Failure restores explicit book/dictionary snapshots and restages files for retry. Startup recovery removes unpublished generations and cleans known obsolete resources after a successful database save.
- `TranscriptParser` handles SRT and WebVTT timestamps, optional identifiers/settings, basic markup, and plain text. Invalid segments fail import with an error. Transcript size is capped at 10 MB. Styling and positioning metadata are intentionally flattened into readable text.
- `TranscriptDocument` maps UTF-16 ranges to segment indexes and looks up the most recently started segment by playback time. For overlapping segments, that segment takes precedence until it ends; gaps have no highlight.
- `PlaybackController` owns AVPlayer and a 200 ms time observer. The reader releases it when dismissed.
- `TranscriptTextView` bridges UITextView for native selection and the dictionary edit-menu action. Highlight changes preserve the text and selection.
- Video uses the same storage, player, and transcript model, with a video region above the transcript.

Media stays local; background playback, local deletion and phrase translation are supported. Lock-screen controls, cloud library sync, arbitrary track editing and automatic alignment of untimed text remain outside the supported workflow. Contextual cloud translation requires explicit opt-in and a user-provided OpenAI key.

## Validation

Run `bash scripts/test.sh` once the Xcode iOS platform and simulator runtime are installed. CI runs unit/UI tests and a Release device build. Unit tests cover parsing, timing boundaries, Unicode ranges, backward seeking, overlap policy, and dictionary persistence. UI tests cover the initial library, import sheet, and dictionary navigation.

Before release, manually verify with a long transcript on iPhone and iPad: selection across paragraphs and while dragging at screen edges, VoiceOver, large Dynamic Type sizes, seeking while paused/playing, file-provider downloads, unsupported media, app relaunch/resume, and audio interruptions. These device interactions are not established by parser unit tests.
