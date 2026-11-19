# Source-linked exam digitizer

Local authoring/import tooling for official Polish certification exams. It does not deploy
a backend, call an AI grading provider, or change the iOS application.

The first reviewed profile is the adult B1 examination from 22–23 June 2024. Preserve
the original module/task/item hierarchy, alternatives, worked examples, spelling and
publisher inconsistencies. The complete paper is retained, including unused answer sheets.
Speaking is explicitly `source_missing`: the paper lists its maximum score but supplies
no oral tasks. Do not substitute invented questions.

## Install and build

Run from the repository root. Python 3.11+ is required. The ordinary build needs no
model, AWS credentials, or network once the downloaded source archive is available.

```sh
python3 -m venv /private/tmp/exam-digitizer-venv
/private/tmp/exam-digitizer-venv/bin/pip install -r tools/exam-digitizer/requirements.txt
/private/tmp/exam-digitizer-venv/bin/python tools/exam-digitizer/exam_digitizer.py build \
  --profile /Users/arublevsky/dev/ExamSources/profiles/b1-2024-06.json \
  --sources-root /Users/arublevsky/dev/ExamSources \
  --audio-alignment /private/tmp/exam-digitizer-audio/aligned/audio.json \
  --output /Users/arublevsky/dev/ExamSources/generated/pl-b1-2024-06-adults-v1
```

Outputs must be new directories; existing packages and originals are never overwritten.
The builder checks the input manifest's size and SHA-256, validates structure and score
totals before writing, stages the result, and publishes the directory only on success.
The content revision is derived from the reviewed profile, original-file identities and
audio metadata. Rebuilding unchanged inputs produces the same exam revision.

The optional `--no-render` omits page PNGs. Omitting `--audio-alignment` produces a clearly
flagged package without task playback markers, rather than fabricated intervals.

## Output contract

| Artifact | Purpose |
| --- | --- |
| `exam.json` | Versioned backend import source: metadata, ordered modules/tasks/questions, text, options, keys, rubrics and original-page references. |
| `exam.schema.json` | JSON Schema 2020-12 for the import document. Additional semantic checks are implemented by `validate`. |
| `profile.json` | Reviewed authoring input used to build this package. |
| `audio.json` | Original-audio identity, actual task occurrences, repetition roles and quality evidence. |
| `ai-assessment.json` | Grammar V/VI official-key/rubric contracts, prompt fingerprints, strict score/rationale output schemas and empty-answer request templates. No inference is performed. |
| `sources/` | Unchanged paper PDF, transcript/key PDF and MP3, with their original filenames. |
| `evidence/extracted.json` | Page-by-page layout text, physical dimensions and source references. Text extraction is evidence, not a verified question parser. |
| `evidence/page-index.json` | Each rendered PNG's original source/page and checksum. |
| `alignment/` | Raw ASR, official reference, actual aligner outputs, subtitles, verification and source-bound provenance. Temporary WAV clips are excluded. |
| `web/` | Snapshot of the local simulation UI for this package. |
| `quality-report.json` | Counts, score/structure checks, missing modules, audio summary and explicit limits. |
| `artifact-manifest.json` | Size, SHA-256 and original-source references for all other package artifacts. The manifest itself carries the same original-source references. |

Source IDs are `paper`, `keys`, and `audio`. Every content element has `source_refs`;
`page` always means the physical PDF page counted from 1, not the printed module page.
Original download URLs and SHA-256 hashes live in `sources`. Generated artifacts can be
traced through the artifact manifest even when their binary format has no metadata field.

`max_score_units` uses hundredths of an examination point: 25 is 0.25 points and 3000
is 30 points. Section/task sums are checked; writing alternatives are checked individually
and must not be added together. Writing's ambiguous original A/B assessment columns are
retained as source material, not assumed to be the two subtask scores.

For the future backend import, treat `id` + `revision` as an immutable content version.
Import metadata, sources, modules, blocks, items, options and grading rules in one transaction;
retain prior revisions for old attempts. The import package intentionally includes answer
keys. The local simulation is not an anti-cheating or production student delivery service.

## New examinations

For archive-wide extraction, resumable ASR, independent stage statuses and curation
boundaries, see [the batch guide](BATCH.md).

Extract evidence directly from another archive selection:

```sh
/private/tmp/exam-digitizer-venv/bin/python tools/exam-digitizer/exam_digitizer.py extract \
  --sources-root /Users/arublevsky/dev/ExamSources \
  --year 2024 --session '22-23 czerwca' --level B2 \
  --output /private/tmp/exam-b2-evidence
```

Selection uses the exact labels from `manifest.json`, not filesystem directory slugs.
Prepare a new reviewed profile using the rendered pages, extracted text and official key.
Use the existing profile as the field contract, not as content for another examination.
Generic extraction, packaging, validation and simulation are reusable; semantic question
conversion is currently captured in reviewed per-exam profiles. There is no claim that an
arbitrary PDF has been automatically converted or reviewed. Keep unresolved content marked
for review rather than publishing guessed text, answer keys, timings or points.

The audio pipeline is documented in [AUDIO.md](AUDIO.md). Printed transcripts omit repeated
playbacks and some spoken instructions. Locate actual occurrences before invoking the
existing aligner, and bind all cached data to the original audio hash.

## Local simulation

```sh
/private/tmp/exam-digitizer-venv/bin/python tools/exam-digitizer/exam_digitizer.py validate \
  /Users/arublevsky/dev/ExamSources/generated/pl-b1-2024-06-adults-v1
/private/tmp/exam-digitizer-venv/bin/python tools/exam-digitizer/exam_digitizer.py serve \
  /Users/arublevsky/dev/ExamSources/generated/pl-b1-2024-06-adults-v1 --port 8773
```

Open `http://127.0.0.1:8773/`. The server binds only to loopback and supports MP3 byte-range
requests for seeking. No source upload or external grading request occurs. Training allows
pausing, changing answers, section completion and exporting an attempt. Responses/timers
persist in browser storage scoped to package identity/revision.
Correct answers and key links are shown after section submission.

Exact and set answers are evaluated against the official key. Grammar V/VI's free formulations
and partial-credit rubrics use `ai_stub`: no fabricated score or pass/fail is issued. The
server also exposes `POST /api/grade` with `{revision, responses, selected_tasks}` as a local
backend-integration stub. It returns objective points separately from pending AI/manual
results; a nonfinal section total is `null`. Writing's shared rubric remains a task-level
pending maximum. A real evaluator can later replace the stub without changing the source
content or losing official rubric/page references.

The 1.1 package also supports `token_membership` for listening V's two-answer rows.
Read runs of ASCII digits separated by any other characters, count each distinct correct
number once, and award `max_score_units / accepted_answer_count` per match. Enforce the
original number of answer slots: listing all numbers is invalid. Wrong numbers add no
points and repeated numbers cannot inflate the result. Reading IV's numeric display codes
retain an explicit map to the original A–H option IDs and original key references.

Only `interactive_section_ids` (listening, reading, grammar) are used by this preview and
its local grading endpoint. Writing is retained in the import and speaking remains explicitly
source-missing; neither is used in the interface. Tables, one shared option bank, inline text
fields and inline choice fields are driven by each task's `presentation` metadata.

Choose training or exam before starting. Training has a bounded play/pause/seek bar on each
listening card. Exam plays the original complete MP3 once, including its embedded repetitions,
with read-only progress and no pause/seek controls. After a forced interruption, resume from
the saved position. Browser controls are not a proctoring/anti-tampering boundary.

For future native assessment, reuse the existing translation integration's captured provider,
model, reasoning settings and credential route. `ai_assessment.py` prepares source-bound
requests and validates exactly `{score_units, rationale}`; the web interface performs no AI
request. The native/backend changes and locally persisted, cross-device synchronized attempts
are described in [the implementation plan](../../docs/EXAM_IMPLEMENTATION_PLAN.md).

## Checks

```sh
/private/tmp/exam-digitizer-venv/bin/python -m unittest discover -s tools/exam-digitizer -p 'test*.py' -v
node tools/exam-digitizer/web/test.mjs
```

Tests cover source corruption, immutable revisions, page/option/gap references, score sums,
writing alternatives, partial/pending grading, audio source identity/intervals, path confinement,
and HTTP byte ranges. Real-alignment quality evidence is distinct from these contract tests.
