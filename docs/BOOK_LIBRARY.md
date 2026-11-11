# Curated book library

The library shares the existing operator API and Cognito authorization. The app stores a manually
pasted operator **access token** in a separate device-only Keychain entry, under Settings →
Встроенная библиотека. The operator client currently issues 15-minute access tokens. Replace the
token when it expires; the app does not store passwords or refresh tokens.

## API

- `GET /v1/library/books` → `{schema_version: 1, books: [{id, title, language, bytes, sha256}]}`.
- `GET /v1/library/books/{id}/download` → `{schema_version: 1, url, expires_in: 900, bytes, sha256}`.

Both routes require the existing Cognito JWT scope and the live `operator` identity check, including
the pinned subject. Only catalog IDs can be downloaded. S3 is private; signed URLs are bearer
credentials usable for 15 minutes, even if the Cognito session is subsequently revoked. Do not log
or share URLs. Downloads stream to disk, verify byte count and SHA-256, then open the existing
complete ZIP import wizard. The ordinary manifest, synchronization, vocabulary, preview and commit
validation all apply. Cancel/retry and expired-token errors are available in the library screen.
ZIPs are removed after the import sheet closes. Imported files remain available offline.

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
