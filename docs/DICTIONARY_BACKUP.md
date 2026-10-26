# Dictionary backup and restoration

Use **Library → Backup Library → Backup Library** to save a library-state JSON snapshot outside the app's storage. This restores progress after reimporting the same books on another phone, without embedding their files.

## Library backup and new-phone restore

1. On the old phone, choose **Library → Backup Library → Backup Library** and save the JSON to Files or another location outside the app.
2. On the new phone, import the same book packages (or the same single media/transcript pairs). Local book IDs and titles may differ.
3. Choose **Library → Backup Library → Import Library**, select the backup, review the matched books and press Restore.
4. Enter your OpenAI API key separately in Settings if needed.

The library backup includes all dictionary v3 data listed below, studied reading words, book/chapter/part completion flags and playback positions, active track, original book titles/dates/languages, a resumable training round including retries, both editable prompt texts, model/cloud settings, level cooldowns and up to 200 cached detailed word explanations. Original word levels and change dates preserve learning cooldowns. API keys stay in Keychain. Book text/audio/subtitles/alignment files and derived vocabulary indexes are excluded; saved phrase context is included in dictionary data.

Books match by normalized source text and ordered track IDs/durations rather than their new local UUID or title. Phrase-audio links are remapped to matched local books; their file paths and timing sidecars stay those of the newly imported package. Use the same edition/package and track layout. If a book is missing or ambiguous, or a dictionary identity conflicts, the preview lists the issue and disables Restore. Resolve it, cancel and import the backup again. Do not remove duplicate books that have local data you need; save their backup first. The format does not apply partial book restores or store pending unmatched progress.

Restore replaces matching saved states, settings, cached explanations and the training checkpoint; unrelated local books/entries are retained and studied words are merged. Importing the same backup again is safe. Model-save failure rolls back dictionary, book and vocabulary changes and restores the previous cache; settings are applied only after successful model save. Keep the source JSON until you have verified restoration. This is a portable state backup, not a replacement for keeping the original book packages.

## Older dictionary JSON backups

**Library → Backup Library → Import Library** also accepts dictionary JSON v1–v3 as Restore backup. **Import Dictionary JSON** provides Restore backup, Merge dictionary and Update translations only. These older files contain only the dictionary/reading-vocabulary subset, not book progress or settings. The sections below describe that embedded/legacy dictionary format.

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

Choose **Library → Backup Library → Import Dictionary JSON → Restore backup**, select the JSON file, review the counts and press Apply.

New IDs are added. Matching IDs with the same original text and languages have their saved fields and progress restored, even when their translation has not changed. An ID with different original text or languages is treated as a conflict and kept local. Other local entries are retained. A failed database save rolls back the import.

**Merge dictionary** adds missing records with their backup details, but updates only nonconflicting translations on existing records. **Update translations only** never adds entries and preserves existing progress and details.

**Restore backup** and **Merge dictionary** also merge the studied reading vocabulary. Existing words are retained, duplicates use the earliest first-studied date, and repeated imports are safe. Preview shows new and already-studied counts. Dictionary and reading vocabulary are saved atomically; failure rolls back both. If local knowledge changes after preview, review the refreshed preview before applying.

**Update translations only** leaves reading vocabulary unchanged. Older v1/v2 backups do not change local reading vocabulary. A fresh installation can restore studied words without any books, then immediately use them for new-book counts and highlighting.

Schema v1 files still restore their available text, translations, origins, context and levels. They do not contain the additional v2 fields; those cannot be reconstructed from the old file. When restoring over an existing record, absent legacy details do not erase its newer notes or analysis.

## Audio boundary

The legacy/embedded dictionary payload is a dictionary backup, not an audiobook/library archive. It does not embed recordings, subtitles, library records, chapter/book completion marks, playback positions, API keys or app settings. Reading vocabulary survives deleting or reimporting a book; a reimported book starts with new completion marks. Keep original media packages separately.

Audio metadata survives restoration, but Play phrase requires the original library item UUID, track ID and local audio file. Reimporting the same audiobook creates a new library identity and does not automatically reconnect old dictionary entries. With no matching local book, the phrase and all other dictionary data remain usable and audio is shown as unavailable.

## Validation and limits

The importer accepts schema versions 1–3. V1/v2 retain the 20 MiB limit. V3 allows 64 MiB total, at most 50,000 dictionary entries and 500,000 reading word forms; combined UTF-8 language/form content is limited to 32 MiB. It rejects duplicate IDs, invalid levels, unsupported versions, invalid text or language metadata, incomplete v2/v3 backup details, invalid audio ranges and invalid context selections. V3 requires a version-1 readingVocabulary section, canonical language tags and normalized single word forms; duplicate language/form pairs and unsupported tokenizer versions are rejected. Source context must contain at most 2,000 UTF-16 units and its selected text must match the phrase. Export runs the same validation before producing a file, so an invalid or oversized backup is reported instead of silently producing an unusable export.
