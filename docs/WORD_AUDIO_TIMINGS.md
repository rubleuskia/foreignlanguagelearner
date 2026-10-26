# Word-level phrase audio

The reader, selection preview, dictionary and learning screens use aligned word boundaries when the selected spoken words all have positive, valid timings. Otherwise playback uses subtitle cue bounds and the button says **Play context**. Word boundaries come from acoustic alignment; the app never estimates them by dividing a cue's duration by characters or words. Model-provided timestamps are not a guarantee of listening accuracy.

## Importing and updating a book

New `.book.zip` packages can carry optional word-timing JSON on each timed track. Existing schema-v1 packages without this field remain importable.

For an existing book, open its reader and choose **Update phrase audio** in the toolbar. Select either an upgraded book ZIP or a smaller timing-only update ZIP. The app validates the track IDs/order, subtitle text, local audio SHA-256, durations and timing structure before attaching any files. It preserves the book ID, track IDs, reading completion and playback progress. Unambiguous saved dictionary selections receive updated audio bounds, including in subsequent dictionary backups. A failed database save restores the previous metadata and removes the prepared update files. Ambiguous repeated phrases and words with unusable timings retain their existing playback range.

Timing-only ZIPs contain `manifest.json` and its referenced word-timing files. They are for **Update phrase audio**, not the library's new-book importer. That importer still requires all declared media, subtitles and TXT. Updates do not replace audio or subtitles. The local media library remains the source of audio; no network operation is added.

## Package contract

A timed manifest track may add:

```json
"wordTimings": "word-timings/001.json"
```

Untimed tracks cannot reference word timings. The existing book format/schemaVersion remains 1 with this optional extension; earlier app versions with strict manifest validation cannot read packages using the new field.

Each sidecar has this shape:

```json
{
  "schemaVersion": 1,
  "trackID": "001",
  "audioSHA256": "<64 lowercase hex characters>",
  "textSHA256": "<64 lowercase hex characters>",
  "words": [
    {"text": "Przewędrował", "start": 22.0, "end": 22.6},
    {"text": "ulicami", "start": 22.6, "end": 23.1}
  ]
}
```

`textSHA256` hashes the parsed subtitle text after `aligner-nfc-whitespace-v1` normalization. `words` must cover every whitespace-delimited token of that text, in order, including standalone punctuation. Text is checked token by token and mapped to actual UTF-16 ranges in the reader. The hash binds the normalized text; line wrapping and cue separators do not change it.

Times are finite **seconds local to the physical audio file**, with `0 <= start <= end <= duration` and nonoverlapping word order (a 1e-6-second tolerance only accommodates floating-point arithmetic). Zero-duration tokens remain explicit. A selection containing a zero-duration spoken token falls back to cue playback. Standalone punctuation does not widen word playback bounds. Selections across cues are supported. The app keeps track-local media identities and does not infer audio for untimed full-book TXT.

Limits: 10 MB per sidecar, 50 MB combined; book ZIP limits continue to apply. Audio hashes are verified using streamed reads at import/update. The immutable local media contract permits a bounded parsed-document cache during reading and dictionary playback. Missing/corrupt optional local sidecars degrade to context playback; invalid declared sidecars reject a new import/update.

## Preparing data without rerunning recognition

Ordinary `batch_align.py` publishing now includes compact sidecars from its saved alignment reports. To upgrade a previously generated unpacked book:

```sh
python3 tools/subtitle-aligner/word_timings.py \
  --book /path/to/existing/book \
  --alignment-directory /path/to/results/tracks \
  --output /path/to/new.book.zip
```

Add `--timings-only` to produce a small update ZIP without copying the audio, subtitles or TXT. Output must be a new filename. The command verifies cached alignment fingerprints against the actual audio when a fingerprint is present, checks word text/timing order, preserves explicit zero-duration tokens and applies any cached `offset_seconds` exactly once. It does not run models or change source files.

## Lalka validation, 19 October 2026

The final cached conversion remains at `tools/subtitle-aligner/output/lalka-final-2026-10-16/` in the original local checkout. Its `tracks/<ID>/alignment.json` files cover **39 tracks and 258,855 tokens**, including **9,589 zero-duration tokens**. All 39 final SRT files match the supplied `Documents/dev/AudioBooks/lalka/lalka.book.zip` byte for byte. The final audio hashes also pass cached-fingerprint verification; no new recognition was required.

Generated artifacts are under the implementation checkout's ignored `tools/subtitle-aligner/output/lalka-word-audio-2026-10-19/`: `lalka.book.zip` for a new import and `lalka-phrase-audio.zip` for an existing-book update. The sidecars contain 13,529,961 uncompressed bytes.

The actual Swift parser and timing validator accepted every track and all 258,855 token mappings. A standalone run additionally checked the calculated selections for **241,166 spoken tokens with positive duration**. These counts measure structural consistency and selection calculations, not acoustic accuracy. The zero-duration count includes punctuation; it is not a word error rate.

A checked-in test preserves a real excerpt from track 001: selecting `polityczny zajmował` uses **53.62–54.74 seconds**, while its subtitle cue spans **49.68–55.44 seconds**. Automated tests also cover Unicode, cross-cue selection, repeated text, missing/invalid timings, wrong track/audio, old track decoding, new-book import, existing-book updates, progress preservation and save rollback. Full-book listening review has not been performed.
