# Curated book library

The library shares the existing operator API and Cognito authorization. Sign in under Settings →
Built-in library with the operator username and password. Access and rotating refresh tokens live
in device-only Keychain entries; the session renews automatically and the password is not saved.

## API

- `GET /v1/library/books` → `{schema_version: 1, books: [{id, title, language, bytes, sha256, ...metadata}]}`.
- `GET /v1/library/books/{id}/download` → `{schema_version: 1, url, expires_in: 900, bytes, sha256}`.

Both routes require the existing Cognito JWT scope and the live `operator` identity check, including
the pinned subject. Only catalog IDs can be downloaded. S3 is private; signed URLs are bearer
credentials usable for 15 minutes, even if the Cognito session is subsequently revoked. Do not log
or share URLs. Downloads stream to disk, verify byte count and SHA-256, then open the existing
complete ZIP import wizard. The ordinary manifest, synchronization, vocabulary, preview and commit
validation all apply. Cancel/retry and expired-token errors are available in the library screen.
ZIPs are removed after the import sheet closes. Imported files remain available offline.

## Book identity and presentation

`id` is the permanent catalog identity, independent of ZIP checksum, book title and local UUID.
Keep the source directory name (the catalog ID) unchanged when updating a package. The importer
persists it as `LearningItem.builtinLibraryID`, including in library backups. The catalog displays
“Already in library” and opens the existing book. The final import commit also checks the ID and
normalized text/ordered track IDs, preserving the original book, phrases and reading progress.
Deleting the local book permits a new download. Existing duplicates are not deleted automatically.

Older imports acquire the ID by an exact fingerprint of normalized full text plus ordered track IDs,
without matching editable titles. Fingerprinting for catalog reconciliation runs off the main actor.
An import with different content or a changed track layout is not automatically associated.

Rows reuse the main library's dark background and 76 × 96 cover images. Metadata includes author,
language, chapter count and ZIP size; reading progress, duration and vocabulary statistics are omitted.
The author disclosure contains a short biography and a source link. `App/Resources/BookLibraryMetadata.json`
contains researched English/Russian/Polish summaries, source URLs and existing bundled cover choices
for the initial nine titles. These generic covers are not original edition artwork. Older API catalogs
use that bundled fallback, so no backend deployment is needed for these titles.

Catalog metadata fields `author`, `authorInfo` (language-code → text), `authorURL` (HTTPS), `coverName`,
`chapterCount` and `contentFingerprint` are optional. API values override bundled fallback values.
The publication script copies editorial author/cover fields from the bundled metadata file and computes
chapter counts and content fingerprints directly from the source packages. Unknown titles remain
downloadable with a generic cover and their available metadata. Add verified author information to
the metadata file when publishing new books; the app does not scrape web pages at runtime.

## Storage and publishing

`infra/book-library-storage.json` owns the independent retained storage stack
`ForeignLanguageLearnerBookLibrary-prod`. Deploy it in `eu-north-1` before deploying the operator
release. It creates `fll-book-library-<project ID>-eu-north-1` with encryption, versioning, public
access blocked and HTTPS enforced. The operator CDK assembly imports this bucket and grants its
handler read-only access to `library/*`; it cannot publish or delete books.

Prepare publication with:

```sh
python3 scripts/prepare-book-library.py /path/to/AudioBooks build/book-library
```

This validates CRCs for every member of each `*/*.book.zip`, reads manifest metadata and computes
SHA-256. It excludes raw source archives, dictionaries and processing folders. Upload each source
listed in `uploads.json` to its corresponding S3 key, then publish `catalog.json` as
`library/catalog.json` **last**. Content-addressed ZIP keys preserve the previous catalog during
failed uploads. Archive objects are immutable by convention; never replace an existing hash key.
Old versions/archives remain retained and incur storage charges until explicitly retired.

Release the operator handler/routes/IAM changes through the existing verified-main CI tag and
Cloud Control preparation/deployment flow (see OPERATOR_CLOUD.md). The new API is unavailable on
older operator releases. The app defaults to the current operator endpoint; an alternative build
can set `BookLibraryAPIBaseURL` in its Info.plist. The value must be a trusted HTTPS operator API.

## Initial publication, 2026-11-11

Nine complete packages from `/Users/arublevsky/Documents/devtest/AudioBooks`, 4,382,975,309 bytes:
Trzej muszkieterowie, Alicja w Krainie Czarów, Don Kichot z La Manchy, Człowiek z blizną,
Dolina trwogi, Hrabia Monte Christo, Bolesław Prus — Lalka, Robinson Crusoe, Mały Książę.
The source ZIPs already contain text, audio and alignment files; source directories are not repacked.
