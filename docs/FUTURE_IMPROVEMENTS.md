# Future improvements

**Status:** General project backlog, not an implementation order or a list of shipped features.  
**Updated:** 2026-09-22.

This document records work deliberately deferred while testing and developing the application. It covers the product as a whole rather than one feature. Detailed contracts remain in their individual implementation plans. Do not implement a backlog item merely because it is listed here; select its scope and acceptance criteria first.

The current testing decision is to allow public cloud processing without sign-in, with private per-job access tokens, bounded admission and a 60-minute recording limit. Accounts and production hardening are future work. Existing local workflows must continue to work without an account.

## Access, identity and ownership

**Before a production service is opened broadly:** introduce account authentication and a server-verified owner for private resources. Define sign-in, sign-out, token expiry/revocation, account recovery, account deletion and device loss. Decide whether guest activity can be adopted into an account and how ownership is proven; possession of a public resource ID is not proof.

Acceptance: a user cannot read, change or delete another user's resources; revoked credentials stop granting new access; recovery never reveals another user's data; local reading/import/practice remain usable without signing in.

## Abuse controls and operating costs

**Before removing testing caps:** add durable per-user allowances, rate limits, bounded retries, admission control and cost attribution. Decide how anonymous traffic, automated clients and repeated uploads are handled. Define operator controls to suspend new work separately from cancelling work already running.

Acceptance: simultaneous requests cannot exceed admitted limits; retrying an accepted request does not charge or run twice; alerts have owners and response instructions. Budget alerts are distinguished from enforced spending limits. Measure storage, networking and idle infrastructure costs as well as compute.

## Data lifecycle, portability and recovery

**Before expanding remote storage or cross-device workflows:** document which data is local, temporary or persistent; retention periods; export/import compatibility; backup exclusions; deletion and recovery. Distinguish user-facing access expiry from verified physical deletion.

Decide explicitly whether deleting source media should preserve saved vocabulary. The current app deletes locally linked dictionary entries with their library item; changing that policy requires a separate product decision and migration tests. Likewise, portable dictionary JSON currently does not carry usable local audio links.

Acceptance: failed saves/imports/deletions do not leave a misleading success state or destroy unrelated data; interrupted operations recover on relaunch; schema changes open representative old stores; exports remain usable when media is absent.

## Reliability and diagnosability

**As workflows become asynchronous or use more services:** standardize operation IDs, explicit state transitions, cancellation, retryable errors and recovery after uncertain responses. Build operator runbooks for stuck jobs, failed upgrades, missing files and unavailable dependencies.

Acceptance: every long-running operation reaches a visible terminal/recoverable state; stale callbacks cannot overwrite newer work; logs and diagnostic exports avoid unnecessary source content and credentials. Diagnostic collection and retention are explicit, bounded and testable.

## Performance and supported limits

**Before increasing input sizes or claiming support for longer/larger content:** measure startup time, memory, disk, battery, playback transitions and processing time on representative devices and workloads. Maintain reproducible benchmark fixtures and documented environment/version information.

Acceptance: supported limits follow measurements rather than file-size guesses; text rendering and progress saves avoid loading/rewriting an entire library; users receive actionable messages for limits. Changes that require streaming, chunking, caching or preloading get a separate architecture review.

## Product clarity and accessibility

**Before broad release:** audit terminology, empty/error/review states, progress semantics, localization, VoiceOver, Dynamic Type, contrast, reduced motion and iPad layouts. Clearly distinguish viewing from saving, local from remote processing, and an estimate from verified timing or learning progress.

Acceptance: users can explain what an action stores/sends, recover from a failure, and complete the primary workflows without relying on color, a precise gesture or a small screen size. Optional persisted settings should have defined ownership, defaults and reset behavior before being added.

## Quality, content compatibility and dependencies

**Before expanding supported formats, languages or automatic processing:** create a compatibility matrix and quality evaluation set. Track upstream dependency versions, licenses, security fixes and platform availability. Separate structural validity from content correctness: parsable subtitles and successful translation calls do not prove timing or meaning is accurate.

Acceptance: new algorithms/formats have representative success and failure fixtures; upgrades preserve established behavior; uncertain generated output is labeled for review; dependency updates have a rollback path. Automated chapter matching, source replacement, richer exports and other expanded workflows require their own concrete proposal.

## Delivery discipline

For any item selected from this backlog, specify:

1. The user problem and exact included/excluded behavior.
2. Data/API/state contracts, migration and failure handling.
3. A bounded implementation sequence with measurable acceptance cases.
4. Deployment/rollback implications and operational ownership, where applicable.
5. Updates to `knowledgebase/CHANGELOG.md`, `DECISIONS.md` and, when boundaries/workflows change, `PROJECT.md` in the implementation PR.

Do not label these improvements complete until code, verification and any required operational work are complete. Planning decisions do not change the description of the currently shipped application.
