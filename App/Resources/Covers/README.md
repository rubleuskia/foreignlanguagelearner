# Bundled book covers

Six user-supplied photographs from the redesign conversation are shipped as local JPEG resources.
The existing source watermarks are preserved. Filenames are stable identifiers persisted in SwiftData
and optional library-backup metadata. `cover-books` is the default for existing books.

Images have a maximum edge of 1,200 pixels and JPEG quality 72; the complete collection is
1,296,743 bytes (about 1.24 MiB). No network requests or full-resolution originals are needed.
Custom and archive covers are separately normalized by `BookCoverService` to a maximum edge
of 1,200 pixels and JPEG quality 75, then published with the staged book transaction.
