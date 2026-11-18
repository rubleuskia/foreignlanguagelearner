# Exam audio markup

The audio adapter reuses `tools/subtitle-aligner/align.py`; it does not introduce a second forced-alignment engine. The first supported reference profile is the adult B1 exam of 22-23 June 2024, `profiles/b1-2024-06.audio-reference.json`.

## Input and source identity

The curated reference JSON records the original MP3 and transcript/key PDF URLs and SHA-256 values. Its `path` fields are relative to the `ExamSources` root. It preserves the extracted transcript, the text used for alignment, PDF page references, and any corrections to PDF extraction artifacts. The importer must retain both the source and those corrections.

Each task specifies start/end search phrases and the expected number of recorded occurrences. Published transcripts normally contain each passage only once, while the recording also contains instructions, item numbers, pauses, and repeated playback. Never align a single unrepeated PDF transcript against the entire recording as if they were identical texts.

## Reproduce the full pipeline

Run from the repository root. The example uses the already-installed local aligner environment; another environment with the same Stable-ts/Whisper/PyTorch dependencies, NumPy and SciPy can be substituted. FFmpeg and ffprobe must be on PATH. This pilot was run with Stable-ts 2.19.1, PyTorch 2.14.1, multilingual `base`, CPU and six threads. The cached model was reused, with no cloud processing.

```sh
ALIGN_PYTHON=/Users/arublevsky/dev/foreignlanguagelearner/tools/subtitle-aligner/.venv/bin/python
EXAM_AUDIO=/Users/arublevsky/dev/ExamSources/originals/2024/22-23_czerwca/B1/22-23.06.2024-B1_pilk_dzwiekowy.mp3
RUN_DIRECTORY=/private/tmp/exam-audio-rebuild

"$ALIGN_PYTHON" tools/exam-digitizer/audio_transcribe.py \
  --audio "$EXAM_AUDIO" \
  --source-url https://certyfikatpolski.pl/wp-content/uploads/2025/02/22-23.06.2024-B1_pilk_dzwiekowy.mp3 \
  --output "$RUN_DIRECTORY/rough-transcription.json" \
  --model base --language pl --threads 6

python3 tools/exam-digitizer/audio_markup.py \
  --reference tools/exam-digitizer/profiles/b1-2024-06.audio-reference.json \
  --audio "$EXAM_AUDIO" \
  --transcription "$RUN_DIRECTORY/rough-transcription.json" \
  --output "$RUN_DIRECTORY/aligned" \
  --aligner tools/subtitle-aligner/align.py \
  --python "$ALIGN_PYTHON" --model base

"$ALIGN_PYTHON" tools/exam-digitizer/audio_verify.py \
  --alignment-directory "$RUN_DIRECTORY/aligned"

python3 -m unittest discover -s tools/exam-digitizer -p 'test_audio_markup.py' -v
```

Choose new output paths for every run. Existing recognition files and alignment output directories are refused rather than overwritten. `--locate-only` performs source-bound ASR anchor detection without forced alignment and explicitly records `forced_alignment_executed: false`; this is useful for inspection, not a substitute for the full pipeline.

The transcription cache is bound to the original audio SHA-256 and its own SHA-256 through an adjacent `.provenance.json`. Reusing a cache with a different audio recording fails before any alignment. The markup step also checks the original audio hash against the reference profile. Missing anchors, unexpected repeat counts, reordered passages, overlapping ranges and invalid timestamps fail instead of creating guessed times.

## Output package

- `aligned/audio.json`: task-to-occurrence mapping; source identity, original-relative millisecond ranges, role `primary`/`repeat`, anchor evidence, forced-alignment quality and review state.
- `aligned/evidence/`: published alignment input text, raw ASR transcript, source-bound provenance, and per-occurrence `alignment.json`, SRT, VTT, normalized text and source provenance. `verification.json` contains the independent bounds/repetition/coverage audit.
- `aligned/work/`: temporary mono PCM WAV crops. They are intermediate inputs, not files to ship in the backend import package.

When importing, copy `evidence/` to the package's `alignment/` directory. `audio.json` artifact links already use that destination prefix. Preserve the original MP3 separately in `sources/` and rewrite only its portable local path during packaging. The source URL and SHA-256 remain unchanged.

`start_ms` and `end_ms` are relative to the untouched original MP3, not to a crop. They bound the published listening passage, including its worked example and embedded pauses; the ranges exclude introductory instructions and repeat announcements. Keep the entire original recording for exam mode so those instructions and pauses remain intact.

The engine JSON word times and per-occurrence SRT/VTT are relative to the individual WAV crop. To map them back to the original MP3, add the interval start recorded in the occurrence's provenance. The provenance also records the clip hash and original audio interval. Do not attach a crop-relative VTT directly to the original full MP3 without applying this offset.

Every derived text/subtitle/JSON artifact has a source chain: its per-task or per-occurrence provenance records the original URL, SHA-256, PDF page references, derived artifact hashes and coordinate system. The full package artifact manifest adds package-level integrity.

## Pilot verification result

The real existing aligner was run separately on all nine recorded occurrences and all nine calls succeeded. The official reference text was preserved in each result. This verifies text coverage and structural validity, not perfect word timing.

- Five tasks: task I once, tasks II-V twice.
- Nine ordered ranges, all inside the original MP3, with no overlaps.
- 1,334 aligned whitespace-delimited words across all occurrences.
- 38 words (2.849%) lack a positive individual duration. These remain in the subtitle text and are explicitly flagged; their timestamps are not fabricated.
- Repeat verification independently compares two eight-second waveform probes per repeated passage, one near its beginning and one near its end.
- Tasks II, IV and V pass the waveform threshold of 0.98, with beginning/end offsets agreeing within 25 ms.
- Task III has correlations 0.91833063 and 0.95490981, below that deliberately strict threshold; both probes find the same repeat offset of 138,824 ms. It remains `requires_review`, not silently certified.

All machine-generated ranges retain `requires_listening_review`, and `human_listening_review_performed` is false. The pilot demonstrates that the current aligner can produce useful passage mappings and review subtitles for exam recordings. It does not certify every word boundary or replace listening review. In the exam emulator, use whole-passage playback and the unchanged original full recording; do not require word-level timing to take the exam.
