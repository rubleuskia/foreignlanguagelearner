# TXT + audio → synchronized subtitles

A local command-line utility for turning a **matching UTF-8 book transcript and an audio recording** into **SRT and WebVTT** files that Foreign Language Learner can import. Alignment estimates when the supplied words are spoken; no timestamps are required in the TXT.

This utility lives outside the iOS target. Run it on a development computer, review the result, then import the audio and one subtitle file into the app. It does not modify the book, audio, Xcode project, or library database.

## Contents

- [App compatibility](#app-compatibility)
- [Requirements and installation](#requirements-and-installation)
- [First conversion](#first-conversion)
- [Preparing matching inputs](#preparing-matching-inputs)
- [Command reference](#command-reference)
- [Output files and timing conventions](#output-files-and-timing-conventions)
- [Chapters and excerpts](#chapters-and-excerpts)
- [How alignment and subtitle grouping work](#how-alignment-and-subtitle-grouping-work)
- [Import and quality review](#import-and-quality-review)
- [Troubleshooting](#troubleshooting)
- [Development and validation](#development-and-validation)
- [Engine choice and limitations](#engine-choice-and-limitations)

## App compatibility

The implementation builds on `codex/media-transcript-library`:

- [`TranscriptParser.swift`](../../App/Services/TranscriptParser.swift) reads UTF-8 SRT, WebVTT, and untimed TXT.
- [`MediaImportService.swift`](../../App/Services/MediaImportService.swift) imports the transcript alongside playable media and limits transcript size to 10 MB.
- [`MEDIA_LIBRARY.md`](../../docs/MEDIA_LIBRARY.md) describes playback, transcript selection, highlighting, and dictionary behavior.

Generated subtitles have numbered cues, explicit hours/minutes/seconds/milliseconds, blank lines between cues, and nonempty text. SRT uses comma milliseconds; WebVTT uses dots and a `WEBVTT` header. Literal `<`, `>`, and `&` are escaped so the app's markup removal preserves those characters.

The app highlights **whole cues**, not individual words. JSON is retained for inspection or future word highlighting; the app does not import it. SRT and VTT contain equivalent text and timing: choose either one.

## Requirements and installation

Use Python 3.11 or 3.12 as a starting point, FFmpeg on `PATH`, and enough free disk space for PyTorch and model weights. Model size substantially affects download size, memory use, and processing time. CPU is the default, including on Macs; this wrapper exposes CUDA for machines with a suitable NVIDIA/PyTorch installation. It does not expose Apple's MPS backend.

Run these commands **from the repository root**:

```sh
brew install ffmpeg
python3 -m venv tools/subtitle-aligner/.venv
source tools/subtitle-aligner/.venv/bin/activate
python -m pip install -r tools/subtitle-aligner/requirements.txt
python tools/subtitle-aligner/align.py --help
```

On Linux, install FFmpeg using your package manager instead of Homebrew. GPU users should install an appropriate PyTorch build following its official instructions before installing the requirements.

The engine is pinned to `stable-ts==2.19.1`. Transitive dependencies are not fully locked; the environment is not claimed to be reproducible across all platforms. After validating your environment, capture it with `python -m pip freeze` if you need a record of the exact installed versions.

The first run downloads the selected Whisper model. Later runs reuse its cache. Set `--model-dir tools/subtitle-aligner/.cache` to keep weights in an ignored directory inside this utility. Without this option, the engine uses its normal cache location. Audio and text processing happens locally; dependency/model downloads need internet access. Preload the model before working offline.

The utility's `.venv/`, `.cache/`, `samples/`, `output/`, and Python bytecode are ignored by Git. Put personal books and generated artifacts in those locations rather than committing them.

## First conversion

Start with a short excerpt and its exact narration. For example, put `excerpt.txt` and `excerpt.mp3` in `tools/subtitle-aligner/samples/`, then run:

```sh
python tools/subtitle-aligner/align.py \
  --text tools/subtitle-aligner/samples/excerpt.txt \
  --audio tools/subtitle-aligner/samples/excerpt.mp3 \
  --language pl \
  --model small \
  --device cpu \
  --model-dir tools/subtitle-aligner/.cache \
  --output tools/subtitle-aligner/output/excerpt-01
```

The output directory must **not already exist**. Its parents are created automatically. This prevents accidental replacement of previous results; use `excerpt-02` when trying new settings. Subtitles are generated only after alignment and timing validation succeed. If word validation fails, `alignment-failed.json` preserves the raw engine result and `normalized.txt` preserves the input for diagnosis; no subtitles are written. A filesystem failure during writing can also leave a partial directory; inspect it and rerun into another directory.

Success prints cue/word counts and exits with status 0. Input, alignment, and ordinary runtime errors exit with status 1 and a message on stderr. Invalid command-line arguments exit with argparse's status 2.

### Public Polish sample

“Latarnik” by Henryk Sienkiewicz is available from [Wolne Lektury](https://wolnelektury.pl/katalog/lektura/latarnik/):

- [MP3 narration](https://wolnelektury.pl/media/book/mp3/latarnik.mp3)
- [TXT edition](https://wolnelektury.pl/media/book/txt/latarnik.txt)

Download both yourself and prepare a matching excerpt first. The downloaded TXT may include editorial information, notes, or license material that is not narrated. A book page listing both files does not establish that every character matches the recording. Keep source attribution and applicable licensing information with your test assets.

## Preparing matching inputs

1. **Use the same text as the recording.** An abridged audiobook cannot be aligned reliably to the entire unabridged book. Check edition, chapter order, introductions, repetitions, and omissions.
2. **Save as UTF-8 TXT.** A UTF-8 BOM is accepted. Polish diacritics are preserved and normalized to Unicode NFC. Old Windows encodings must be converted before running.
3. **Remove material that is not spoken.** Page numbers, running headers, footnotes, indexes, editor credits, and end-of-file publishing information commonly need manual cleanup.
4. **Repair extraction artifacts.** Join words broken by page/line hyphenation only when appropriate. Keep actual hyphenated words. The utility intentionally does not guess which hyphens to delete.
5. **Match spoken numbers and abbreviations when necessary.** A printed date or abbreviation may need its spoken form in the alignment copy. Keep the original edition separately; this utility does not map normalized words back to original page positions.
6. **Match the audio interval.** A 3-minute audio clip needs only the words spoken in that clip. Do not pair it with an entire chapter.

The automatic cleanup only removes BOM characters, normalizes Unicode, and collapses whitespace. It does not remove footnotes or infer missing narration. Paragraph breaks become spaces; subtitle grouping is computed from word timings and punctuation.

### PDF sources

PDF input is deliberately outside this utility's scope. Extract text first, correct it, and save a TXT. PDFs containing scanned images need OCR. For selectable-text PDFs, a PDF extraction tool may still introduce page headers, incorrect reading order, and split words. Prefer the publisher's TXT/EPUB edition where available. See [pypdf's extraction discussion](https://pypdf.readthedocs.io/en/stable/user/extract-text.html).

### Audio sources

The engine decodes local audio through FFmpeg. Common inputs include MP3, WAV, and M4A, subject to the codecs in your FFmpeg build. There is no extension whitelist; decoding determines support. DRM-protected files are not supported. Being decodable by FFmpeg does not guarantee the iOS app can play that codec; MP3 or AAC/M4A are practical starting points.

## Command reference

| Argument | Default | Meaning |
|---|---|---|
| `--text PATH` | Required | Nonempty matching UTF-8 `.txt` file |
| `--audio PATH` | Required | Nonempty local audio file |
| `--output PATH` | Required | New directory for generated artifacts |
| `--language CODE` | `pl` | Whisper language code, e.g. `pl` or `en`; validated by the engine |
| `--model NAME` | `small` | Model name or local checkpoint path accepted by Stable-ts |
| `--device cpu\|cuda` | `cpu` | Inference device |
| `--model-dir PATH` | Engine default | Download/cache location for weights |
| `--format srt\|vtt\|both` | `both` | Which subtitle files to write |
| `--max-chars N` | `42` | Positive target characters per line; at most two lines per cue |
| `--max-duration SECONDS` | `6` | Positive target cue duration |
| `--max-gap SECONDS` | `0.8` | Nonnegative pause threshold for splitting cues |
| `--offset SECONDS` | `0` | Nonnegative time added to subtitle cues, not an audio trim |

Use multilingual models for Polish: `tiny`, `base`, `small`, `medium`, or another multilingual checkpoint supported by your engine. Avoid `.en` models for Polish. Smaller models are useful for plumbing tests; evaluate timing with a larger model before relying on the output. No processing-time or accuracy guarantee is provided.

Line length and duration are **targets**. A single word longer than the requested line width or cue duration remains intact and can exceed that target. Words are never split in the middle to satisfy formatting. This implementation's whitespace/line-breaking rules target languages such as Polish and English; they are not specialized for unspaced writing systems.

## Output files and timing conventions

| File | Contents | Import into app? |
|---|---|---|
| `subtitles.srt` | Numbered timed text; comma milliseconds | Yes |
| `subtitles.vtt` | WebVTT header and timed text; dot milliseconds | Yes |
| `normalized.txt` | Exact normalized text supplied to alignment | Optional, but untimed |
| `alignment.json` | Engine output plus exported cue data and run metadata | No |

Only requested subtitle formats are written. The normalized TXT and JSON are always written on success. UTF-8 subtitle output must be smaller than 10,000,000 bytes, conservatively respecting the app's import limit.

JSON has utility `schema_version: 1`, `language`, `model`, `offset_seconds`, descriptive timestamp-unit fields, a `cues` array, and the engine's full `alignment` object. Each cue contains `start` and `end` as **integer milliseconds including the offset**, and `text` as an unescaped string. Engine word timings in `alignment.segments[].words[]` remain **seconds relative to the input audio**, without the offset. Do not confuse those two coordinate systems. Raw engine fields can vary with engine versions.

The sidecar preserves word timings, not source PDF coordinates or original text character offsets. Cue times are rounded to milliseconds with carry across seconds/minutes/hours.

## Chapters and excerpts

For long books, work chapter by chapter to reduce the cost of rerunning a bad section. This version processes one pair per invocation; it does not automatically locate chapters, reconcile different editions, batch a manifest, or merge subtitle files.

For example, extract 180 seconds starting at 600 seconds into a book:

```sh
ffmpeg -i tools/subtitle-aligner/samples/book.mp3 \
  -ss 600 -t 180 -ac 1 -ar 16000 \
  tools/subtitle-aligner/samples/chapter-excerpt.wav
```

Prepare the TXT for precisely that interval. If importing the **excerpt audio**, leave `--offset 0`. If importing the **original full audio**, use `--offset 600` so the generated cues start at the matching position in the full recording:

```sh
python tools/subtitle-aligner/align.py \
  --text tools/subtitle-aligner/samples/chapter-excerpt.txt \
  --audio tools/subtitle-aligner/samples/chapter-excerpt.wav \
  --offset 600 \
  --format srt \
  --output tools/subtitle-aligner/output/chapter-excerpt-full-timeline
```

An offset shifts all cues equally. It cannot correct progressive drift, omitted paragraphs, or a differently edited recording. When merging independently generated chapters with an external tool, order cues by start time, renumber SRT cues, keep only one WebVTT header, and check boundaries for duplicates/overlaps. Never simply concatenate complete WebVTT files.

## How alignment and subtitle grouping work

1. Validate paths/options and read/normalize TXT before loading a model.
2. Load the selected model through Stable-ts and call `model.align` with the supplied text and explicit language. This does not ask the model to generate a replacement transcript.
3. Extract word timings from the result. Check that concatenated aligned text equals the normalized input; fail if text disappeared or changed.
4. Reject missing/non-finite/negative timestamps, words with zero duration at millisecond precision, or word overlap at that precision. Nothing is silently dropped or stretched to fabricate a usable timeline.
5. Accumulate words into cues. Split before exceeding two wrapped lines or the target duration, across a pause longer than `--max-gap`, and after sentence-ending punctuation. These punctuation rules are simple heuristics; abbreviations can create short cues.
6. Apply the optional offset to cue times, escape subtitle markup, validate output size, and write artifacts.

These structural checks do **not** prove that a positive-duration word is aligned to the correct sound. Forced alignment can assign plausible times even to mismatched text. Human listening review remains necessary. Strict validation can also reject an otherwise mostly useful alignment when a word receives zero duration; shorten/correct the input or try another model instead of treating the error as success.

## Import and quality review

1. Transfer the matching audio and `subtitles.srt` or `subtitles.vtt` to Files on the iPhone/iPad or another file provider.
2. In Foreign Language Learner, choose **Upload item**.
3. Select the audio and generated subtitle file, then choose **Import**.
4. Play the beginning, middle, and end; inspect chapter transitions, pauses, names, and numbers.
5. Seek backward and forward and check that the active passage tracks the narration.
6. Select a phrase and use **Add to Dictionary** to check the existing reader flow.

Pauses between cues intentionally have no active highlight. Review unusually short/long cues and the positions around any omitted content. Compare `normalized.txt` with the recording when investigating errors. A successful import establishes format compatibility, not acoustic accuracy.

## Troubleshooting

| Symptom | Action |
|---|---|
| Missing `stable_whisper` / install requirements message | Activate this utility's virtual environment and install `requirements.txt` with that environment's Python |
| FFmpeg missing | Install FFmpeg and verify `ffmpeg -version` works in the same terminal |
| Model download fails | Check network access and available disk space; retry with the same model cache directory |
| CUDA failure | Use `--device cpu`, or install a matching GPU/PyTorch environment |
| TXT decoding error | Convert the file to UTF-8; do not rename a PDF to `.txt` |
| Zero-duration, overlapping, or missing word error | Check omissions/introductions; test a shorter exact excerpt and another multilingual model |
| Valid subtitles drift progressively | Check that text and audio are the same edition; an offset will not fix this |
| All cues are consistently early/late | Check excerpt offsets and whether the imported audio is the excerpt or original |
| Output directory exists | Choose a fresh output directory; there is no force-overwrite option |
| Process killed / memory exhaustion | Choose a smaller model or shorter chapter and close memory-heavy processes |
| Subtitle rejected for size | Process smaller chapters and import them with matching chapter audio |
| Audio decodes here but fails iOS import | Convert to an iOS-playable format, preserving the timeline, and retry |

## Development and validation

Files:

- `align.py`: command-line interface, engine adapter, validation, cue grouping, and serializers.
- `requirements.txt`: pinned direct alignment dependency.
- `test_align.py`: dependency-free tests for Unicode, timing rejection, grouping, escaping, timestamp rollover, output generation, and overwrite protection.

Run the tests from the repository root without installing ML dependencies:

```sh
python3 -m unittest discover -s tools/subtitle-aligner -v
python3 tools/subtitle-aligner/align.py --help
```

The CLI test uses a **fake engine** and dummy audio. It verifies file generation and error handling, not speech recognition quality. A real-engine smoke test must also be performed in an installed environment with matching speech and text. For release-quality Polish evaluation, use a manually checked Polish excerpt and listen to the output; synthetic English smoke tests are insufficient to establish Polish accuracy.

Changes to subtitle serialization should also be checked against the app's actual Swift parser. Existing app tests run through `bash scripts/test.sh` when the iOS simulator platform is installed. The utility is not installed by iOS CI and is not embedded in the app.

## Engine choice and limitations

[Stable-ts](https://github.com/jianfch/stable-ts#alignment) provides direct untimed-text alignment, fitting this utility's initial TXT + audio contract. Its repository was archived on May 30, 2026 and development is paused. The pinned package is a prototype dependency with an explicit maintenance risk; evaluate a replacement before depending on it for unattended production processing.

[WhisperX](https://github.com/m-bain/whisperX) is a possible alternative. Its [alignment implementation](https://github.com/m-bain/whisperX/blob/main/whisperx/alignment.py) includes a Polish model, but its interface expects text segments with approximate audio intervals. Supporting arbitrary books robustly would require a coarse transcription/text-matching stage before that alignment step. This utility does not implement that pipeline.

Other current limitations: no PDF extraction/OCR, GUI, automatic chapter detection, subtitle editor, automatic correction of abridgments, confidence-based review UI, translation, source character mapping, or on-device iOS inference. Model artifacts are cached locally and outputs are estimates that need review.
