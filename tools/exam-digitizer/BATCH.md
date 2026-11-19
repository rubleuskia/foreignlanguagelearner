# Archive digitization queue

The archive snapshot contains 44 source sets. The initial June 2024 adult B1 package
is kept unchanged; the batch prepares the other 43. Original filenames, archive
labels, source URLs and SHA-256 values remain authoritative. A scheduling priority
does not normalize or correct an original exam date.

## Separate stages

1. **Evidence extraction:** original PDF page text, full-page PNGs, physical-page
   indices and heading candidates. `evidence_ready` is not a reviewed interactive test.
2. **Rough ASR:** source-bound local recognition of the complete original recording.
   Successful recognition does not prove complete text coverage, task/repetition
   boundaries or word timing. Preserve quality flags and original raw output.
3. **Curation:** independently check the exam hierarchy, text, examples, keys,
   response slots, score rules and presentation against the original paper/key PDFs.
   Record unsupported types and publisher ambiguities instead of adapting them to June.
4. **Audio alignment:** locate actual occurrences using the official per-exam reference,
   then run the existing aligner on the corresponding original intervals. Retain targeted
   ASR recovery evidence and offsets where the full-recording ASR omitted a passage.
5. **Import package:** build and validate a new immutable package only after its profile
   is curated. Acoustic review, source ambiguities and AI limitations remain explicit.

## Start or resume

From the repository root:

```sh
/private/tmp/exam-digitizer-venv/bin/python tools/exam-digitizer/batch_digitize.py init \
  --sources-root /Users/arublevsky/dev/ExamSources \
  --batch-root /Users/arublevsky/dev/ExamSources/digitization
/private/tmp/exam-digitizer-venv/bin/python tools/exam-digitizer/batch_digitize.py evidence \
  --sources-root /Users/arublevsky/dev/ExamSources \
  --batch-root /Users/arublevsky/dev/ExamSources/digitization --workers 2
/Users/arublevsky/dev/foreignlanguagelearner/tools/subtitle-aligner/.venv/bin/python \
  tools/exam-digitizer/audio_batch.py \
  --sources-root /Users/arublevsky/dev/ExamSources \
  --batch-root /Users/arublevsky/dev/ExamSources/digitization \
  --model base --language pl --threads 6
```

Both stages use locks and atomically publish complete outputs. Resuming rechecks
source/artifact identities. Corrupt completed evidence is retained as a failure,
not overwritten as fresh success. A different download manifest needs a new batch
directory. PDF work uses separate processes because the renderer is not thread-safe.
The audio model is loaded once and recordings are processed sequentially.

## Inspect progress and provenance

```sh
/private/tmp/exam-digitizer-venv/bin/python tools/exam-digitizer/batch_digitize.py status \
  --batch-root /Users/arublevsky/dev/ExamSources/digitization
```

The batch root contains `batch-index.json`, `evidence-run-status.json` and
`audio-run-status.json`. An exported `curation-index.json` records independently
validated packages and the verification timestamp; it is separate from automated
preparation counts. Each original year/session/level directory contains:

- `evidence-status.json`, `evidence/extracted.json`, `page-index.json`,
  `structure-draft.json`, page PNGs and `artifact-manifest.json`;
- `audio/status.json`, `audio/asr/rough-transcription.json`, adjacent provenance,
  readable text, quality report and artifact manifest. Invalid timestamps remain
  flagged; an invalid subtitle file is not invented.

The batch source/artifact audit is stored as `verification.json` when exported.
It verifies bytes and hashes, not the semantic correctness of questions or ASR.
Curated profiles belong outside Git in `ExamSources/profiles/`; validated exam packages belong in
`ExamSources/generated/`. Do not import heading candidates or raw ASR as exam answers.

## Findings from the next two adult B1 sets

February 2024 contains 125 interactive responses; April contains 126. Their listening
V row/slot counts differ. All numeric rows use membership parsing with the original
slot limit, including one-answer rows. Examples never add points. Writing alternatives
stay in JSON without assuming that the original A/B rubric columns are subtask weights.

Assessment ambiguity notes derive from the actual item's annotated source rubric;
a June task number alone must not inject June's note into another exam. Content-review
images retain their relative subdirectories so paper and key pages with the same name
cannot overwrite each other. Existing immutable packages are never rewritten.
