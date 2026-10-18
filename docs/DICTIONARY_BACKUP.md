# Dictionary backup and restoration

Use **Dictionary → Transfer → Export Dictionary Backup** to save a JSON snapshot. Keep the file outside the app's storage. New exports use schema version 3 and always include saved source context.

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
- Studied word forms from confirmed read chapters/books, with source language, first-studied date and tokenizer version. These are independent of dictionary cards. Export also works when the dictionary is empty.

Active requests and their internal revision counters are not restored. Dates accept both whole-second and fractional-second ISO 8601 representations.

## Restore

Choose **Dictionary → Transfer → Import Dictionary → Restore backup**, select the JSON file, review the counts and press Apply.

New IDs are added. Matching IDs with the same original text and languages have their saved fields and progress restored, even when their translation has not changed. An ID with different original text or languages is treated as a conflict and kept local. Other local entries are retained. A failed database save rolls back the import.

**Merge dictionary** adds missing records with their backup details, but updates only nonconflicting translations on existing records. **Update translations only** never adds entries and preserves existing progress and details.

**Restore backup** and **Merge dictionary** also merge the studied reading vocabulary. Existing words are retained, duplicates use the earliest first-studied date, and repeated imports are safe. Preview shows new and already-studied counts. Dictionary and reading vocabulary are saved atomically; failure rolls back both. If local knowledge changes after preview, review the refreshed preview before applying.

**Update translations only** leaves reading vocabulary unchanged. Older v1/v2 backups do not change local reading vocabulary. A fresh installation can restore studied words without any books, then immediately use them for new-book counts and highlighting.

Schema v1 files still restore their available text, translations, origins, context and levels. They do not contain the additional v2 fields; those cannot be reconstructed from the old file. When restoring over an existing record, absent legacy details do not erase its newer notes or analysis.

## Audio boundary

This is a dictionary backup, not an audiobook/library archive. It does not embed recordings, subtitles, library records, chapter/book completion marks, playback positions, API keys or app settings. Reading vocabulary survives deleting or reimporting a book; a reimported book starts with new completion marks. Keep original media packages separately.

Audio metadata survives restoration, but Play phrase requires the original library item UUID, track ID and local audio file. Reimporting the same audiobook creates a new library identity and does not automatically reconnect old dictionary entries. With no matching local book, the phrase and all other dictionary data remain usable and audio is shown as unavailable.

## Validation and limits

The importer accepts schema versions 1–3. V1/v2 retain the 20 MiB limit. V3 allows 64 MiB total, at most 50,000 dictionary entries and 500,000 reading word forms; combined UTF-8 language/form content is limited to 32 MiB. It rejects duplicate IDs, invalid levels, unsupported versions, invalid text or language metadata, incomplete v2/v3 backup details, invalid audio ranges and invalid context selections. V3 requires a version-1 readingVocabulary section, canonical language tags and normalized single word forms; duplicate language/form pairs and unsupported tokenizer versions are rejected. Source context must contain at most 2,000 UTF-16 units and its selected text must match the phrase. Export runs the same validation before producing a file, so an invalid or oversized backup is reported instead of silently producing an unusable export.
