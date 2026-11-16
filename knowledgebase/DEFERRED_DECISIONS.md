# Decisions and work required before release

## Large books and paid access

Current imports enforce existing size and track limits and return explicit validation
errors when exceeded. This is intentional for the initial operator version. Before release:

- Define free/paid size, duration and chapter limits, entitlement checks and UI messaging.
- Support large books through bounded per-chapter processing, storage and retry budgets.
- Validate a short work, ordinary audiobook and long multi-chapter novel end to end.
- Define mobile-network automatic download policy and confirm interrupted-download behavior.

## Catalog operations and quality

- Deploy the catalog-capable API/worker and populate metadata through manual refresh.
- Verify the complete provider catalog and attribution in real generated packages.
- Confirm expiry policy for cached source files and permanent retention of prepared packages.
- Complete iOS build/device verification and representative alignment/listening acceptance.
- Decide update notifications and explicit replacement flow preserving local vocabulary
  and reading progress; never silently overwrite an imported book.
