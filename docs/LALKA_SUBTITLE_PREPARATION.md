# Lalka: preparing a long audiobook from EPUB

## Source and mapping

The supplied Wolne Lektury edition contains `lalka.epub` and a ZIP with 39 MP3 recordings narrated by Albert Osik. Total audio duration is 115,449.952449 seconds (32 h 04 min 10 s); the longest track is about 158 minutes. Inputs and generated book artifacts remain local and are not committed to the repository.

`epub_text.py --profile wolne-lektury` follows the OPF spine and produces 44 reading sections plus an index of 18 excluded publisher/annotation documents. Five standalone book/volume title sections are excluded from audio matching. The actual correspondence is:

| Audio tracks | EPUB documents | Content |
| --- | --- | --- |
| 001–020 | `EPUB/part4.xhtml`–`EPUB/part23.xhtml` | Volume I, chapters I–XX |
| 021–038 | `EPUB/part26.xhtml`–`EPUB/part43.xhtml` | Volume II, chapters I–XVIII |
| 039 | `EPUB/part44.xhtml` | Uzupełnienie |

The 39 chapter texts contain 258,855 whitespace-delimited source tokens. Chapter numerals in the EPUB were checked against MP3 filenames. Inline emphasis and punctuation remain intact; footnote references, annotation text, fundraising and publishing pages are excluded. The source EPUB hash and every chosen section are recorded in the local source index/mapping.

## Narration boundaries

Short speech-recognition probes at the start and end of representative recordings identified publisher introductions and the closing announcement. Alignment analyzes track 001 from 40 seconds, track 021 from 30 seconds, track 020 up to 3,834 seconds, and track 039 up to 491 seconds. The volume-I outro was found during the later full-track recognition check. All other recordings use their full duration. These bounds affect inference only: offsets are restored to the original MP3 timeline, and every delivered audio file is byte-for-byte identical to its source.

## Timing and review

The local conversion uses Stable-ts 2.19.1 with the cached multilingual Whisper `base` model on CPU. Rough transcription supplies matching passage anchors; the subtitle text always comes from the EPUB.

A first pass with 60-second targets exposed local timing drift. Retesting chapters 003 and 004 with 20-second targets removed the previously observed differences greater than five seconds in matched phrase checks. This evidence motivated the shorter default and alignment core version increment in the utility. Actual intervals depend on available anchors; sparse matches can still create longer intervals.

A local second pass retries selected passages with approximately eight-second targets when several lexical tokens have no duration or a word has an unusually long duration. Candidates are retained only when the timing-degeneracy metrics improve without worsening the other metric. Original and revised artifacts remain available locally. This is a heuristic improvement, not proof of acoustic accuracy.

A further diagnostic identified skipped recognition passages in tracks 026 and 036; fresh recognition and alignment of the bounded intervals repaired them.

All tracks retain `review-required` status. Zero-duration tokens remain in neighboring cues rather than being dropped or given invented timestamps. Matching against rough recognition can confuse repeated phrases and uses the same underlying model, so it is a diagnostic rather than an independent accuracy measurement. The full 32-hour book has not been manually listened through.

## Delivery and validation

The local delivery contains an importable `lalka.book.zip`, separate SRT and VTT directories named after the original MP3 files, a readable UTF-8 text, source mapping, timing-review diagnostics, checksums, and the original `informacje.txt` credits/license information. The strict app package itself contains only its manifest, referenced audio, text and subtitles.

Final output has 34,399 cues per format across all 39 tracks. The second pass improved 437 passages; the additional boundary/recognition corrections cover three intervals. There are 9,589 tokens without individual nonzero duration, including 5,258 lexical tokens; they remain represented in surrounding cues and all tracks keep review status.

Validation completed:

- All 258,855 source tokens are preserved exactly after normalized whitespace, both in alignment words and rendered cues.
- Every cue has positive duration, no overlap, and stays inside its original recording.
- The app's actual Swift `TranscriptParser` accepted all 39 SRT/VTT pairs with identical parsed segments.
- The app's actual `BookManifestValidator` accepted all 39 tracks, transcript hash and contiguous text ranges.
- The ZIP contains exactly 80 referenced files, passed CRC validation, and its 39 copied MP3s match the source SHA-256 values.
- All 21 subtitle-tool unit tests passed, including EPUB extraction and the shorter guided-window regression. The real EPUB was independently re-extracted by the committed tool and matched the text used for alignment.

The local delivery also contains `validation.txt`, per-track conversion statistics, heuristic recognition-comparison diagnostics and a SHA-256 file list. No full-book human listening review is claimed.
