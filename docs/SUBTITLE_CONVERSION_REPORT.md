# Subtitle utility: implementation and Latarnik conversion report

This report records the work performed on September 15–16, 2026, including failed attempts. It distinguishes successful file generation from verified timing accuracy. See the [utility README](../tools/subtitle-aligner/README.md) for installation and current usage.

## 1. Outcome

The supplied Polish audiobook and TXT were converted into **613 SRT/WebVTT cues**, preserving **4,747 normalized source tokens**. Here, “tokens” means whitespace-separated book words or standalone punctuation, not the model's internal tokenizer units.

| Item | Result |
|---|---|
| Original input | `tools/subtitle-aligner/samples/latarnik.ogg` and `latarnik.txt` |
| Audio duration | 2,507.339887 seconds, approximately 41:47 |
| Successful model | Multilingual Whisper `base`, through Stable-ts 2.19.1, CPU |
| Successful strategy | Rough transcription → matching text anchors → 40 bounded alignment passages |
| Output | `tools/subtitle-aligner/output/latarnik-subtitles/` |
| SRT size | 54,567 bytes |
| WebVTT size | 54,575 bytes |
| First cue | 00:00:28.060–00:00:30.460, author and title |
| Last cue | 00:41:16.080–00:41:16.680 |
| Zero-duration source tokens | 280, retained in surrounding cues and flagged |
| Engine-inserted duplicate tokens | Two, removed only after comparison with the source |
| App format validation | Both files parsed successfully; 613 positive, nonoverlapping cue intervals, all inside the recording |

**The output is a review version.** It has not undergone a full manual listening review. Passing the parser and preserving every source word does not establish that every subtitle appears at the correct instant. In particular, 280/4,747 tokens—about 5.9%—have no usable individual duration. That is a timing-review count, not a measured word-error rate.

## 2. Repository context and initial design

The work started from the fetched `codex/media-transcript-library` branch, at commit `313b688`. I created `codex/txt-audio-subtitle-utility` from that branch and opened [PR #5](https://github.com/rubleuskia/foreignlanguagelearner/pull/5) against it. The media-library work is [PR #4](https://github.com/rubleuskia/foreignlanguagelearner/pull/4).

Inspection established that the app accepts UTF-8 SRT and WebVTT for synchronized highlighting, while TXT is untimed. It highlights complete cues rather than individual words, and transcript imports are limited to 10 MB. The utility therefore writes ordinary numbered cues plus JSON diagnostics; no alignment engine is embedded in the iOS app.

Stable-ts was chosen because its alignment API accepts untimed text directly. The direct dependency is pinned to 2.19.1. Its archived upstream status is documented as a maintenance limitation. The initial implementation normalized text, aligned it, rejected text differences or invalid word timings, grouped words into cues, and wrote SRT/VTT/JSON into a new directory. Polish and CPU were the defaults. Existing output directories were deliberately not overwritten.

The initial version was too strict to produce useful review subtitles from a long real audiobook: a single zero-duration token caused the entire run to fail. That strict behavior remains the default, but the final implementation adds an explicit review option rather than silently weakening validation.

## 3. Environment and early smoke tests

These problems occurred before processing the supplied book:

1. **Git permissions:** fetching the source branch failed because the sandbox could not write `.git/FETCH_HEAD`. Retrying with the required filesystem approval allowed the fetch and branch creation. This was an environment restriction, not a repository defect.
2. **Dependency download:** the first virtual-environment install could not resolve the package registry from the sandbox. Retrying with network access installed Stable-ts, Whisper, PyTorch, and the supporting libraries. FFmpeg was already available.
3. **Test implementation error:** the first test run failed to import `test_align.py` because a test fixture was missing a closing brace. I corrected the fixture; the initial six tests passed. Later additions brought the utility suite to nine tests.
4. **Synthetic audio generation:** a sandboxed macOS `say` invocation produced a file with no usable audio duration. Running the speech service with the required access produced a 5.66-second recording.
5. **Model download:** the first `tiny` run could not reach the model host from the sandbox. A permitted retry downloaded its weights and ran inference.
6. **`tiny`, ordinary speech:** the first word, “Hello,” received equal start/end timestamps. The utility rejected it rather than inventing a duration.
7. **`tiny`, slower speech plus a leading pause:** I regenerated speech at 140 words/minute and added one second of silence. It still assigned “Hello” zero duration—1.36 to 1.36 seconds in the inspected result.
8. **`tiny`, silence adjustment disabled:** I temporarily exposed an option to disable the engine's silence-suppression adjustment. The zero-duration result persisted, so that experimental option was removed; it is not part of the shipped CLI.
9. **`base`, slower synthetic recording:** the larger cached model completed successfully: **17 words and three cues**. Both subtitle formats subsequently passed the actual Swift parser.

The English smoke test established that the installed engine and export path could work. It did not establish Polish recognition quality or long-book reliability.

## 4. Preparing the supplied book

The user supplied OGG/Vorbis audio and a TXT edition of “Latarnik.” I inspected the start and end of the TXT and probed the audio duration and codec.

The TXT included an ISBN near the beginning and publishing/license material after a separator at the end. Those are not part of the book narration. I created `latarnik-alignment.txt` without the ISBN line and publishing footer. The author, title, narrative introduction, and book content remained. The original TXT was not edited.

I transcribed the first 60 seconds with `base` to locate the actual opening. The rough transcript showed promotional/licensing speech first, followed by the author at about **28.18 seconds**, the title at about **29.62 seconds**, and the narrative introduction at about **31.74 seconds**. The rough transcript contained recognition errors, so its words were not substituted for the book text.

I created `latarnik-narration.wav` by skipping the first 28 seconds and decoding to mono 16 kHz PCM. Alignment used that narration copy. Export added **28 seconds** to each cue, restoring the full recording's timeline. Thus the generated subtitles must be used with the original-length audio, not with the trimmed WAV. Opening and closing promotional speech are intentionally not subtitled.

I also created full-length M4A and, at the user's request, MP3 copies for simulator playback. These conversions did not intentionally trim or change the playback timeline. The original OGG remained unchanged.

## 5. Full conversion attempts, in order

### Attempt A — direct `base` alignment, default text window

Inputs were the prepared TXT and trimmed narration WAV, language `pl`, with a +28-second export offset.

The engine processed the recording but warned that it **failed to align the last 1,333 of 4,747 words**. Inspection showed 1,761 zero-duration entries in the raw result. The raw text also contained an extra repeated `że`, producing 4,748 output entries instead of 4,747.

The CLI reported a text mismatch and wrote no subtitles. I added preservation of failed engine output as `alignment-failed.json`, alongside `normalized.txt`, so an expensive failed run could be inspected instead of discarded. The failure was not simply “words absent from JSON”: the engine retained many words with unusable times, as well as inserting a duplicate.

Evidence: `latarnik-conversion.log`; `output/latarnik-base/alignment-failed.json`.

### Attempt B — direct `small` alignment

I started a larger multilingual model as an alternative. Its approximately 461 MiB download took roughly nine minutes under variable network throughput. Inference then progressed but slowed substantially in parts of the book.

This run was **stopped after the guided workflow produced usable review output**. It did not produce a validated subtitle file, and no claim is made that it would or would not have succeeded if allowed to finish. Broken-pipe and shutdown warnings in its log reflect the interrupted process. Its model weights remained cached.

Evidence: `latarnik-small.log`.

### Attempt C — direct `base` with a wider text window

While `small` downloaded, I tried `token_step=400`, compared with the default 100. The idea was to give each alignment pass more textual context. The option is now exposed as `--token-step` with a 1–442 range.

This did not resolve the sample. The run failed validation at word 11 because of zero duration; its final alignment activity ended around 1,829 seconds of the 2,479-second narration copy, which was also a warning sign for timeline drift. FFmpeg emitted broken-pipe messages after the consumer stopped. No subtitle output from this attempt was accepted.

Evidence: `latarnik-base-wide.log`; `output/latarnik-base-wide/alignment-failed.json`.

### Attempt D — rough transcription and matching anchors

I transcribed the whole narration with `base` to obtain approximate word locations. This took about 76 seconds of model processing in the recorded run. The rough transcript contained 4,463 word entries and recognition mistakes.

I compared normalized words—lowercased with punctuation removed for matching only—against the 4,747 source tokens. There were **320 ordered exact matching runs of at least four words**, including matches near the ending. This supported the hypothesis that the inputs broadly corresponded and that bounding the aligner to shorter passages would help.

The rough transcript was used only to locate matching book passages. The final subtitle wording continued to come from the prepared source TXT.

Evidence: `latarnik-transcription.log`; `output/latarnik-coarse.json`; `output/latarnik-anchors.json`.

### Attempt E — exploratory alignment of 37 passages

An exploratory script split at matching-run boundaries roughly a minute apart, producing 37 text/audio intervals. Each passage was aligned independently, then its local timestamps were shifted back to the narration timeline.

This preserved the complete source text: **4,747 entries**, with **337 zero-duration entries** and no word overlaps. That was a substantial improvement over the unbounded attempt, although it still could not pass strict per-word timing validation.

This experiment motivated the reusable `--guided` implementation. It was exploratory code, not the exact final production command.

Evidence: `latarnik-chunked.log`; `output/latarnik-cuts.json`; `output/latarnik-chunked-raw.json`.

### Attempt F — reusable guided mode, 40 passages

The utility's `guided.py` generalized the approach. It also considers anchors within long matching runs, producing 40 passages for this recording. If a span exceeds three minutes without enough matching anchors, it fails rather than silently attempting a large unsupported interval.

I added `--allow-untimed-words` for explicit review output. This retains zero-duration tokens in surrounding positive-duration cues, records them in JSON, and does not fabricate individual word timestamps. Strict mode still rejects them.

The 40-passage run completed inference but failed exact text validation because the engine inserted two adjacent repeated tokens: `rzekł.` and `szczęśliwy,`. Its failed result was saved; no subtitles were emitted at that stage.

Evidence: `latarnik-final.log`; `output/latarnik/alignment-failed.json`.

### Attempt G — source-verified duplicate repair and cached export

I added a narrowly bounded repair: compare engine token order against the supplied text and remove only extra adjacent identical tokens absent from the source. It does not remove legitimate repeated words in the source, and it refuses to repair unrelated replacements or omissions. Removed entries, their times, and their original indexes are preserved under `alignment.engine_duplicate_words`.

I also added `--alignment-json` so failed/successful cached results can be validated and formatted without repeating inference. Re-exporting Attempt F's saved result with the duplicate repair and explicit untimed-word option succeeded:

- 4,747 source tokens retained.
- Two extra engine tokens removed and recorded.
- 280 remaining zero-duration tokens listed for review.
- 613 valid SRT/WebVTT cues generated.

This cached export is the source of the delivered `latarnik-subtitles` files. The successful final step did not rerun acoustic alignment.

## 6. Exact successful export command

From the repository root, after the preceding guided run had saved its result:

```sh
tools/subtitle-aligner/.venv/bin/python tools/subtitle-aligner/align.py \
  --text tools/subtitle-aligner/samples/latarnik-alignment.txt \
  --audio tools/subtitle-aligner/samples/latarnik-narration.wav \
  --language pl --model base \
  --alignment-json tools/subtitle-aligner/output/latarnik/alignment-failed.json \
  --allow-untimed-words --offset 28 \
  --output tools/subtitle-aligner/output/latarnik-subtitles
```

For a fresh run with the final implementation, replace `--alignment-json ...` with `--guided` and choose a new output directory. The duplicate repair now runs automatically before text validation. Model inference may vary across software versions or hardware; the cached command above is the exact export used for these artifacts.

## 7. What was verified—and what was not

Verified:

- Nine dependency-free utility tests passed, covering Unicode, grouping, invalid timings, intentional repetition, safe duplicate repair, guided anchors, review mode, JSON diagnostics, and overwrite protection.
- A real model produced usable English smoke-test output.
- Both generated Polish subtitle files passed the actual app `TranscriptParser` in a standalone Swift harness.
- Every exported cue has positive duration, cues do not overlap, and their ends are within the audio duration.
- Canonical book text is retained after the documented input cleanup and source-verified removal of two engine duplicates.
- Samples, weights, environments, and generated outputs are ignored by Git; source and documentation are in PR #5.

Not established:

- Full-book listening accuracy or precise timing for every phrase.
- Reliable individual timestamps for the 280 flagged entries.
- General performance on different editions, abridged books, multiple speakers, noisy audio, other languages, or other machines.
- That the archived Stable-ts dependency is suitable for long-term unattended production use.
- That the interrupted `small` run would have solved the task.

The main lesson is that **format correctness, text completeness, and acoustic timing accuracy are separate checks**. The first two are validated here; the third still needs listening review.

## 8. Simulator handoff and the audio-button defect

At the user's request, I placed `latarnik.mp3` and `latarnik.srt` in the booted iPhone 17 Pro Max simulator's local Files provider, under **On My iPhone → Latarnik**. This used the existing Files container; it did not require embedding sample assets in the app.

The user successfully selected the SRT but reported that **Choose audio or video** did nothing. Source inspection found two `.fileImporter` modifiers attached consecutively to the same `Form`. The observed behavior was consistent with the later transcript importer taking precedence over the media importer.

The fix attaches each file importer to its own button, preserving each importer's content-type filters and separate selected URL. Stable accessibility identifiers support regression testing. This is a SwiftUI presentation issue; it is separate from subtitle generation and audio codec support.

With the fixed build installed on the iOS 26.5 iPhone 17 Pro Max simulator, I verified that the audio picker enabled the MP3 and disabled the SRT, while the transcript picker enabled the SRT and disabled the MP3. Selecting both and pressing Import succeeded: the library displayed `latarnik`, **41 min · 613 transcript segments**. The originals remained in the simulator's Files folder for further testing.

The first automated regression-test version opened the picker but attempted to dismiss it through a hidden underlying Cancel button, so the next interaction failed as not hittable. That was a test-navigation error. I changed the test to verify each picker from a fresh app launch, avoiding dependence on system dismissal labels. The completed simulator suite passed **7 unit tests and 2 UI tests**, including `testBothFilePickersPresentDocumentBrowser`. The Debug build and all nine Python utility tests also passed.

## 9. Local evidence and preservation

Raw logs were initially written under `/tmp`. Copies are retained locally under `tools/subtitle-aligner/output/evidence/` where available. Failed alignment results and intermediate experiments are under `tools/subtitle-aligner/output/`. Those paths are intentionally Git-ignored and will not appear in a fresh clone.

The source TXT and OGG were preserved. Prepared TXT, trimmed WAV, full-length MP3/M4A, and generated subtitles are separate files. No source-book cleanup was written back into the originals.
