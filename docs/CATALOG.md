# Operator discovery catalog

Status: implementation on `codex/wolnelektury-catalog`; no AWS deployment, metadata ingestion, or real-model acceptance performed by this change.

## API and storage

The existing book-alignment API authenticates every catalog route through the pinned operator identity:

- `GET /v1/catalog/books`: paginated public metadata, opaque generation/id cursor.
- `GET /v1/catalog/books/{id}`: metadata and original chapter names.
- `POST /v1/catalog/refresh`: create/join the shared refresh job; poll through the existing book-job status API. There is no schedule.
- `POST /v1/catalog/books/{id}/import`: create/join the deterministic shared source-version/pipeline job, or regenerate a missing/failed result.
- `GET /v1/catalog/books/{id}/import`: current source-version job, or `{job:null}` if absent.
- Existing `GET /v1/book-alignments/{id}` and `/result` provide status/progress and version-pinned result download.

The Books catalog table stores complete metadata generations and one active pointer. Failed refreshes do not replace the current generation. Publishing the pointer transactionally checks the refresh job lease, preventing a stale worker from publishing. Source versions include text/audio resource validators; refresh downloads metadata and HEAD responses only.

Source downloads accept only provider-pinned HTTPS API/media paths, including redirects. Download counts are bounded even when Content-Length is absent. Inputs are admitted under the existing 100 MB limit; output is capped at the iOS importer's 100 chapters. Invalid or changed upstream files receive safe error codes. Shared source objects use the temporary artifact bucket's 30-day lifecycle. Prepared results live at `library/catalog-results/<job>/<lease>/book.book.zip` in the independent retained library bucket. Result pointers are version-pinned and worker success writes remain fenced by the durable lease.

A refresh request and import requests use the existing single worker and queue/outbox/recovery mechanisms. Existing local upload alignment remains supported. Refresh is not a bulk audiobook download.

## App and book format

Catalog combines provider metadata with the existing prepared library titles. It does not reconcile editions by title. Default shelves show root works, with nested works reachable through collections and global search. Provider genres remain available while broad genre memberships determine shelves.

The Catalog tab replaces the dedicated Practice tab; dictionary-based learning remains.
The Dictionary toolbar opens the existing Practice screen, including listening practice,
saved rounds, round setup and cooldown settings. A book detail presents chapters, an excerpt when provided, source links, and import/status controls. Pending requests persist locally. While the app stays active after a request, successful results are downloaded and committed using the checked importer and source identity. After reopening or suspending the app, ready requests remain available for explicit download. Duplicate local imports preserve the existing book and progress.

Catalog metadata is cached on device between launches. Opening the tab displays the saved
catalog first and refreshes metadata older than one hour in the background. Refresh and
pull-to-refresh bypass that interval. On a first load, pages appear as they arrive; searching
the whole catalog is complete when loading finishes. Ready-to-download library metadata
loads independently so it does not wait for all provider pages. A failed refresh preserves
the last complete snapshot, and partial pagination never replaces that disk snapshot.
The cache contains shared book metadata only, with no access tokens or signed download URLs,
and is scoped to the configured API. Import requests and user progress remain separate.

Catalog screens share one navigation path with stable request-list, genre and book-ID routes.
Selecting an import request opens its book details and keeps the requests list in the back
path, including while background polling updates statuses.

The client downloads prepared archives through the shared BookDownloadService used by the
built-in library. S3 global and Stockholm regional signed URLs are accepted without rewriting
the signature; redirects remain restricted to supported S3 destinations. Size and SHA-256
are verified before handing an owned ZIP to the importer. Client download fixes need a new
iOS build; existing completed alignment results can be reused.

The provider worker aligns the full text/audio timeline, preserves the original audio chapter boundaries, and projects each aligned word once onto a chapter-local clock. Boundary clipping/empty narration chapters are marked for review. Each timed chapter has separate audio, subtitles, word-timing JSON and its original title. Publisher notices are separated from narrated TXT and retained in `provenance.json`; original EPUBs and available covers are retained in packages. Local book details expose retained source/attribution notices. Read/review uncertain timings before claiming acoustic quality.

## Delivery and remaining acceptance

A new digest-pinned image must declare `catalog-chapters-v1` as well as the existing book queue contract. The image builder and Cloud Control checks reject an older book-only worker. Build/publish an immutable image from a clean committed source and complete the normal verified-release/Cloud Control preparation, review and deployment workflow in eu-north-1. Do not manually overwrite running functions or deploy API routes against the old worker image.

After deployment, invoke the refresh endpoint once and verify the resulting metadata count. No source media will be fetched until import requests are submitted. Exercise one real short book, a multi-chapter book, duplicate concurrent requests, process-loss recovery, oversize validation, and an existing ready ZIP import before claiming production readiness.

Local validation on 2026-11-16: all 316 iOS unit tests, device Release compilation,
35 aligner/worker tests, 76 Cloud Control/benchmark tests, 33 CI tests, 9 YouTube
JavaScript tests, and CDK type/infrastructure assertions passed. The initial complete
UI run passed 53 of 64 scenarios; all 11 failures referenced the removed Practice tab.
After adding Dictionary → Practice and updating those scenarios, all 11 passed on
repeat. Backend discovery now uses the repository import root (`-t .`) to keep
catalog downloader mocks aligned with canonical module imports; the corrected script
passed all 132 backend tests against local DynamoDB without skips.
No live deployment, real-model timing acceptance or catalog import acceptance is claimed.

Deferred before release: measured large-book limits and paid entitlement/charging policy, mobile-download policy, source update UX, cache cleanup and full localization/accessibility/production acceptance. See `FUTURE_IMPROVEMENTS.md`.
