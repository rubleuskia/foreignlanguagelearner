# Dictionary backup and restoration

Use **Dictionary → Transfer → Export Dictionary Backup** to save a JSON snapshot. Keep the file outside the app's storage. New exports use schema version 2 and always include saved source context.

## Included data

- Phrase IDs, original text, languages, creation dates and learning levels 1–4.
- Saved translation, its origin and update date.
- Context text and the exact UTF-16 selection.
- Meaning in context: word explanations, overall phrase translation and analysis date.
- Preferred meaning and personal note.
- Legacy word-help items, cached Polish definitions and their update dates, even though the old UI is no longer shown.
- Source book IDs/title, local source ID, track ID, cue index and phrase audio start/end.
- Translation status/error metadata. On restoration, a usable translation becomes ready; interrupted translation requests become pending rather than remaining stuck in progress.
- Existing app/OS and lookup diagnostic metadata.

Active requests and their internal revision counters are not restored. Dates accept both whole-second and fractional-second ISO 8601 representations.

## Restore

Choose **Dictionary → Transfer → Import Dictionary → Restore backup**, select the JSON file, review the counts and press Apply.

New IDs are added. Matching IDs with the same original text and languages have their saved fields and progress restored, even when their translation has not changed. An ID with different original text or languages is treated as a conflict and kept local. Other local entries are retained. A failed database save rolls back the import.

**Merge dictionary** adds missing records with their backup details, but updates only nonconflicting translations on existing records. **Update translations only** never adds entries and preserves existing progress and details.

Schema v1 files still restore their available text, translations, origins, context and levels. They do not contain the additional v2 fields; those cannot be reconstructed from the old file. When restoring over an existing record, absent legacy details do not erase its newer notes or analysis.

## Audio boundary

This is a dictionary backup, not an audiobook/library archive. It does not embed recordings, subtitles, library records, API keys or app settings. Keep original media packages separately.

Audio metadata survives restoration, but Play phrase requires the original library item UUID, track ID and local audio file. Reimporting the same audiobook creates a new library identity and does not automatically reconnect old dictionary entries. With no matching local book, the phrase and all other dictionary data remain usable and audio is shown as unavailable.

## Validation and limits

The importer accepts schema versions 1–2, up to 20 MB and 50,000 entries. It rejects duplicate IDs, invalid levels, unsupported versions, invalid text or language metadata, incomplete v2 backup details, invalid audio ranges and invalid context selections. Source context must contain at most 2,000 UTF-16 units and its selected text must match the phrase. Export runs the same validation before producing a file, so an invalid or oversized backup is reported instead of silently producing an unusable export.
