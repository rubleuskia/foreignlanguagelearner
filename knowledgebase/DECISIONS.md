# Architectural and product decisions

## Local-first media and persistence

Media is copied into Application Support and metadata/transcript segments are stored with SwiftData. Imports do not require a server or network access, and failed imports clean up their copied files.

Multi-track books use an additive Codable `LearningTrack` array on `LearningItem`. Track IDs are immutable within an imported book and source identity is `(local item UUID, track ID)`. Legacy items remain single-file records exposed through a synthetic `legacy` track adapter; virtual `LearningPart` ranges remain a legacy single-file concept. Additive store compatibility is verified with persistent reopen coverage, and storage failures never fall back to an empty store.

Archive and database changes use a staged transaction protocol with a durable journal. A generated book directory is renamed into the library before the complete SwiftData item is saved; failed saves remove the inserted model and moved directory. Startup recovery derives every path from validated UUIDs. Deletion first moves files into a transaction-specific trash directory, then saves the database deletion, restoring files if that save fails.

## Timed transcript model

The implementation uses “transcript segment” for a timed subtitle passage. SRT and WebVTT are the synchronized formats; TXT stays selectable but untimed. Highlighting is cue-level rather than word-level, while the subtitle utility preserves word timing in JSON for inspection and future work.

Audiobook subtitle times are always local to one physical track. Global playback time is calculated from unrounded verified track durations with half-open track intervals; editable offsets are not stored. Full-book TXT has no inferred audio boundaries. Timed selection stores local cue bounds only when it also stores a `sourceTrackID`; a missing track ID on a multi-track source makes phrase audio unavailable rather than guessing the first track.

## Native selection

Transcript text is bridged to `UITextView` so learners get native selection handles, edge scrolling, and an edit-menu action for adding a phrase to the dictionary. Continuous text is used so selection can cross subtitle boundaries.

## Follow behavior

Automatic transcript following pauses during manual scrolling or text selection. The learner can resume it with “Follow audio.” Overlapping timed segments use the most recently started segment until it ends; gaps have no highlight.

Follow measures the first visual line of the active cue using TextKit 1 after layout. During playback it leaves that line stationary within 35–60% of the usable viewport, otherwise moving it to 40% with native interruptible scroll animation. Geometry changes recalculate the destination without animation; Reduce Motion disables animation. The follow cache includes content size and measured line geometry, and is recorded before scrolling to avoid reentrant layout. Long cues remain cue-level: no within-cue timing is inferred. A user-created nonempty selection pauses playback once and disables follow; moving selection handles does not repeat the pause. Explicit Follow clears the selection and returns to the reading anchor without starting playback. Playback resume and seek actions also invalidate the previous follow destination. Document identity includes cue ranges and source mappings so equal transcript text with changed timing cannot reuse stale highlight or scroll state.

## Subtitle alignment is a separate tool

Untimed text is aligned outside the app using the local `tools/subtitle-aligner` utility. Guided alignment is available for long recordings with drift; review output can retain zero-duration words but is explicitly flagged rather than pretending timing is accurate.

Multi-track batch alignment requires explicit contiguous word ranges and a normalized transcript hash. It preflights all tracks before loading one model, processes sequentially, and publishes an importable package only when every track is aligned or explicitly marked for review. Single-track reruns reuse only artifacts whose complete input/configuration fingerprint still matches.

## Multi-track package and playback

Book package v1 is a strict root `manifest.json` plus one UTF-8 TXT and 1–100 referenced audio tracks, with optional manifest-linked per-track SRT/VTT. Unknown fields and unreferenced strict-package files are rejected. Raw ZIP imports use natural path ordering only as an editable preview suggestion; SRT/VTT files in raw archives are never linked by filename similarity.

Sequential book playback owns one single-file player. Cross-track seeks, automatic transitions, and end notifications are guarded by a book generation plus track identity. The selected rate and explicit play intent survive file replacement, while pause during a pending seek prevents late completion from restarting audio. Track decode errors stop on the named track and remain retryable.

## Optional cloud alignment uses temporary capability-scoped jobs

The repository contains an undeployed AWS implementation for testing remote audio + TXT alignment.
It uses API Gateway HTTP API and Lambda for the control plane, DynamoDB on-demand records and atomic
global counters, a versioned Step Functions Standard workflow, and exactly one CPU-only Fargate task
for each admitted start. The worker runs in public subnets with a public IPv4 address and no inbound
rules, avoiding a continuously charged NAT Gateway. S3 is private, versioned, encrypted with SSE-S3,
and used only for temporary inputs, results and diagnostics.

The test API deliberately has no account sign-in. A client-generated, cryptographically random
32-byte bearer capability authorizes exactly one job; only its SHA-256 hash is stored. Missing or
malformed capabilities return 401, while an unknown job and a capability mismatch both return 404.
This grants private per-job access but does not identify a person, provide account recovery, or
constitute production abuse protection. Global creation, outstanding-upload, daily-start and active
compute limits plus an operator kill switch bound the test exposure.

Workers consume immutable S3 version IDs and declared full-file hashes, never unversioned latest
objects. They may claim a job and record safe progress/output pointers, but only the finalizer can
publish success after validating a complete manifest and artifact versions. Conditional revisions
make terminal state, cancellation and admission release single-winner operations. A scheduled
reconciler repairs uncertain dispatch, discovers tagged tasks when ARN persistence was interrupted,
stops overdue/cancelled work, expires uploads and deletes every S3 object version according to the
24-hour access contract. Lifecycle and DynamoDB TTL remain asynchronous fallbacks.

The shared Fargate task role is a trusted backend boundary with bucket/table access; it is not
per-job IAM isolation. The public test is fixed to Polish, the `base-guided-v1` profile, zero offset,
both subtitle formats, at most 60 minutes, and no automatic inference retry. Deployment is blocked
until the benchmark matrix demonstrates time, memory, disk, quality and cost headroom. Account
ownership, per-user quotas and stronger production abuse controls remain in the general future
improvements backlog.

## Dictionary portability and translation

Dictionary detail prioritizes the source phrase with inline playback and icon-only copy controls, without a playback-speed menu, followed by the saved translation and a compact Meaning in context block. Copy controls throughout the app use icons with descriptive accessibility labels and a checkmark confirmation. The Progress section permits direct selection of levels 1–4, saved immediately with the previous value restored on save failure; level 4 marks a phrase learnt and lowering it makes a translated, ready phrase eligible for practice again. Legacy Word-by-word help and its per-word definition UI are no longer exposed on this card; stored word-help data remains compatible. Contextual explanations and the overall translation remain selectable without dedicated copy buttons.

Dictionary backups use readable JSON v3 (v2 details plus reading vocabulary) with stable entry identity, source context, translation origin, progress, contextual analysis, personal notes, cached word help and exact audio-source links. V1 and V2 remain readable. Restore backup explicitly replaces fields on matching identities and adds missing records without removing unrelated entries; merge and translations-only preserve existing progress and notes. Interrupted requests are not resumed as in-flight state. Export validates its output against the importer and includes source context by default in the UI. Media files and library records remain outside dictionary JSON: audio links work only with the original local item/track identity and available files; reimporting a book under a new UUID does not automatically relink it. The architecture keeps source/target language metadata extensible, with Russian as the initial product need.

Ordinary automatic translation and word-by-word help use Apple Translation. Contextual translation
instead uses OpenAI Responses API structured output so one request resolves the selected expression
against its saved surrounding text and returns a direct translation plus a short explanation. It is
explicitly enabled by the user and is not an offline feature.

The app follows a BYOK boundary: the user supplies an OpenAI API key, which is stored with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` in Keychain and sent in the HTTPS authorization
header directly to OpenAI. The app contains no shared credential, relay URL, account system, or
project-operated quota. Costs and rate limits belong to the key owner's OpenAI account. A relay is
deferred unless a future product version supplies shared credentials, sells quota, or requires
centralized authentication and abuse controls.

The production translation prompt has a versioned default in code and may be overridden locally in
settings for experimentation. Reset removes the override instead of copying another default into
preferences. The strict output contract and instruction that selected text/context are untrusted
data remain application-owned and are appended after either prompt; users can tune translation
behavior without disabling decoding and prompt-injection boundaries.

Both dictionary and reader use one bounded application-wide analysis service with at most one
active and one queued request. Reader Translate in Context remains a preview until an explicit
Add to Dictionary action. That action saves both the primary contextual translation and word
breakdown; direct Add to Dictionary first requests contextual analysis, so failed analysis creates
no partial entry. Capture therefore requires the existing cloud opt-in and user key. A reader
retains only its last successful selection result, keyed by text, full selection context, source,
languages and audio identity, for reuse if the popup is reopened. Dismissal cancels pending saving;
duplicate taps cannot insert twice. New contextual translations use the `openAI` origin in the
existing raw-string field and portable JSON contract.

The v4 request includes `words_to_explain`: whitespace-delimited selected tokens after a
language-specific function-word filter (Polish, English, German, French and Spanish). Filtering
ignores case and surrounding punctuation, never token length; unsupported languages keep their
words. The strict output must match this exact list, including order and repetitions, with source
word, lemma and meaning. The complete selected text and context still reach the model for the
overall phrase translation. Function-word-only selections have an empty breakdown and a required
nonempty overall translation, which remains saveable. UI formatting adds blank lines and hides
empty breakdown controls. The application-owned contract excludes grammar commentary even with a custom
prompt. Empty overall translations, missing expected words, mismatched and oversized results are rejected. Existing dictionary
results are persisted separately from the primary translation;
existing manual/imported text changes only through explicit acceptance. Request identity and
revision checks reject stale completion after retry or dismissal, and failed refresh does not erase
the previous successful pair. The full contract lives in
`docs/FOUNDATION_MODELS_CONTEXTUAL_TRANSLATION_PLAN.md`; the explicit reader-save and v4 output
rules above supersede its earlier preview-only and explanation-format assumptions.

Context errors display an acknowledgement alert and write bounded local JSON diagnostics (last
200 events). Logs contain timestamp, event/error code, model, request UUID, prompt version and HTTP
status when available. API keys, headers, prompt/input text and model response bodies are excluded.
Export logs uses the system file exporter and is available from settings and translation details.
No diagnostic upload is automatic.

Polish monolingual definitions use the public Polish Wiktionary MediaWiki API as an explicit per-word action. The app parses only the Polish-language section, associates numbered examples with numbered meanings, attributes and links the source article, and persists successful results with the existing word-help data for offline reuse. Lookup failures never remove cached content, and automatic/background harvesting is outside the product boundary. The parser is conservative because Wiktionary markup is community-maintained and may evolve.

Polish inflected forms are resolved locally before a fallback Wiktionary request. A reproducible build tool reduces the BSD-licensed SGJP/Morfeusz source feed to unique `surface form → dictionary title` pairs. For the current debugging phase, the complete database is zlib-compressed into the application bundle and expanded into Application Support on first use. Ambiguous forms remain explicit choices for the learner rather than being resolved arbitrarily. A downloadable language pack can replace the bundled resource later without changing the lookup interface.

## Learning parts

Learning content is modeled as virtual parts rather than requiring duplicated media files. This keeps a shared dictionary independent of whether the referenced media exists on another device and supports future practice flows.

## Learning rounds and completion

Start round fills the requested size from eligible learning levels in order (1 before 2 before 3), shuffling within each level. If a lower level has fewer phrases than the round size, the remaining places come from the next level. Each new round reevaluates the pool.

Start round snapshots a unique eligible ID set for a level-aware preliminary review (level 1 reveals immediately; levels 2–3 require Check). Each card offers Start learning (queue at its current level), Move to next level (save one level increase and exclude from this practice round), Mark as known (save level 4 and exclude), or Skip (exclude from this round without changing or saving the entry). Each choice advances the preview, with persistent changes committed before advancement. Stale presentation IDs are rejected and failed saves keep the card and its previous level. Missing/ineligible cards are skipped. The normal practice round starts only after the complete preview, using the IDs explicitly queued for learning; an empty queue finishes the preview directly. Repeat starts a fresh preview.

A practice round keeps its queued ID set and original size. A wrong answer moves the same ID to the pending tail; a right answer completes that entry for the round after its learning-level save succeeds. Deleted or newly ineligible entries are skipped without replacement. Presentation IDs make answer events idempotent, and a failed save leaves level, queue, counters and revealed state unchanged.

After revealing the answer, horizontal swipes left/right invoke the same saved Right/Wrong action as the buttons. A horizontal drag tints the card green/red and animates it offscreen before invoking the answer transaction. Short or vertical gestures do not answer; Reduce Motion suppresses lateral travel. Input is locked during dismissal, and failed saves restore the card. The most recent answer can be undone for three seconds, including on completion: its saved level, queue and counters are restored and the previous card is revealed with a fresh presentation identity. Undo is invalidated by another answer, skipping, starting a new round or leaving training. Failed undo saves preserve the answered state. Successful undo also rewrites the unfinished-round checkpoint to prevent resuming an undone answer.

Round statistics describe attempts and completion inside that round. The completion screen separately queries every stored level-4 Russian entry with a ready, nonempty translation, so it includes phrases learned before the current round.

## Playback intent, speed and phrase sources

The generated application Info.plist declares background audio, paired with the existing
`AVAudioSession` playback/spokenAudio category. Screen inactivity does not pause the reader.
Background playback is supported; lock-screen media controls remain outside this change.
Book reader controls use the active physical track's local position and duration; local seeks
are clamped to that track. The global timeline remains internal for persistence and cross-track
navigation. Legacy virtual-part timers display offsets from that part's start.

Playback keeps user intent separate from `AVPlayer.rate`, which may be zero while seeking or buffering. Pause clears intent so a pending seek cannot restart audio. Playback speed is owned by each controller, starts at 1×, survives pause and media open/close inside that controller, and is not persisted across screens or launches.

Phrase audio resolves only an entry's matching local source item and a finite range within the selected legacy file or exact multi-track track duration. Source identity includes the optional track ID; a multi-track entry without a valid track ID is unavailable rather than falling back to another track. Missing local media remains a text-only experience; the app does not substitute another library item or fetch media from the network.

## Project and release tooling

`project.yml` is authoritative and the Xcode project is generated. CI and publishing use the macOS 26 runner with Xcode 26.6 so iOS 26 Translation APIs are available consistently. CI runs unit/UI tests and an unsigned Release build. Publishing is manual, gated by tests, uses an ephemeral keychain, and uploads to TestFlight or prepares an App Store draft without automatically submitting or releasing.

## Seek synchronization

Playback seeks use generation tokens and completion callbacks. Periodic time observations are ignored while a seek is active, and stale completions cannot overwrite a newer seek. This addresses the observed 2–4 second transcript drift after manual seeking and previous/next navigation.

## Exportable lookup diagnostics

Polish Definition failures are recorded both through Apple's unified `Logger` and in an app-local, file-protected JSON log capped at 200 newest events. Dictionary export embeds a snapshot of these events plus app/OS versions in an optional `diagnostics` field, preserving version-1 import compatibility and requiring an explicit user export before diagnostic data leaves the device. Logs contain the looked-up word and technical error details, but not source sentence context or media content.


## Resumable training rounds

Only level 1 preview cards reveal their answer immediately; levels 2–3 require Check before the preview actions. The translation remains the recall prompt, matching practice mode.

A versioned local UserDefaults checkpoint stores the fixed round IDs, retry order, completed/skipped IDs, counts and presentation token after a successfully saved Right/Wrong answer. Preview-only sessions are not resumed. Completion clears the checkpoint; starting a new round replaces it without reverting earned levels. Restored missing/ineligible entries follow the existing skip path. Word-level changes remain immediate SwiftData saves, independent of closing or completing the round. Training cannot be dismissed by swipe, and Close requires confirmation for an unfinished round with answers. Dictionary and training setup offer continuation across reopening the app.

Progress rows select a level filter, including level 4, in the word list below. Reset restores the separate in-progress and learnt sections.

## Inline word explanations

Detailed word explanations are a second, explicitly requested level of Meaning in context, shared by the selection preview, dictionary card and revealed learning card. Expanding a word opens content in place, not a new screen. Only one row expands at a time; cancellation and failures never replace the concise translation. The dedicated structured response contains a simple definition, contextual meaning, and one or two illustrative phrases with translations. It uses the existing cloud opt-in, Keychain credential and model selection, with a separate fixed prompt rather than the configurable concise-translation prompt.

The existing persisted `source — lemma — meaning` breakdown is decoded only when every line can be matched in order to the exact selected source tokens. Occurrence-specific UTF-16 ranges disambiguate repeated words. Unsupported legacy output is displayed unchanged; no guessed word lookup is issued. A missing surrounding context can use the selected phrase, matching the existing learning fallback.

Successful details are derived data in a bounded 200-record Caches file, keyed by a hash of the word, lemma, exact context/range, languages, model and detailed-prompt version. The cache survives normal relaunches and works offline when present, but may be purged and is excluded from portable dictionary backups. No SwiftData migration or stored-translation overwrite is needed. Cancelled and invalid responses are not cached.

## Isolated agent contributions

New chats start from fetched origin/main on a dedicated codex/ branch. Concurrent work uses separate worktrees. Existing working-copy changes are preserved rather than reset during setup. Historical review reports explicitly identify their reviewed snapshot and require revalidation before their findings are treated as current.

## Vocabulary accumulated from reading

Performance revision (2026-10-19): [persistent vocabulary index and library badges](../docs/READING_VOCABULARY_INDEX_ARCHITECTURE.md). Unique book-word memberships and an inverted SQLite index update cached counts from newly studied forms. SwiftData remains authoritative. Startup/restore snapshot reconciliation repairs missed projection writes; ordinary updates deliver idempotent deltas. This replaces the proposed outbox with snapshot recovery. New knowledge is stored in bounded append-only batches in the same main-context transaction as completion flags, avoiding thousands of managed inserts without introducing a competing playback writer. Backup v3 remains a union of canonical forms and earliest dates; legacy individual records remain readable. This supersedes the per-word completion storage and full vocabulary reload described below.

Library badges count the full completion corpus (TXT plus subtitles): unread books show new unique forms, explicitly completed books show total unique forms. Reader decoration is limited to the viewport using compact cached positions; text itself remains in a single UITextView. The implementation deliberately retains the existing atomic writer rather than moving all library and dictionary writes to a new actor. Startup knowledge loading uses a background read-only context; large backup work and full-document text layout still require physical-device profiling.

[Reading vocabulary architecture](../docs/READING_VOCABULARY_ARCHITECTURE.md) records the complete behavior and implementation sequence (2026-10-18). Distinct surface forms from confirmed read texts are stored by canonical source language. Completion requires confirmation, cannot be undone, and never creates or changes dictionary cards. Whole-book completion is explicit because tracks cannot establish coverage of the full untimed TXT; it includes full text and all available track subtitle text. Tracks without subtitles may be marked read without contributing words.

A versioned Unicode tokenizer supplies all completion, import statistics and reader ranges. Knowledge is durable SwiftData data independent of library lifetime. Older completion flags migrate idempotently; failures leave migration retryable. The application's main ModelContext is the sole writer for both playback and completion, with unrelated changes flushed before a short synchronous atomic save. This avoids stale cross-context arrays overwriting completed track/part flags. Failed completion explicitly restores observed flags in addition to rolling back inserted words.

Reader new-word foreground color and optional accessibility underline are independent of the active cue background; color-only changes preserve native selection and following. Tokenization is asynchronous, cached for the active text, and not repeated on playback ticks. Language is locked after the first completion to preserve the namespace used for accumulated knowledge.

Portable JSON v3 carries reading vocabulary together with dictionary details, without library files or completion flags. Restore and merge form a union and retain the earliest first-studied date; translations-only and v1/v2 files leave reading vocabulary untouched. Both domains share one save/rollback, and vocabulary changes invalidate stale import confirmations. V3 is limited to 64 MiB / 500,000 reading forms with 32 MiB of language/form bytes; v1/v2 retain their 20 MiB limit. No partial export or silent truncation is allowed.


## Reader paint and chapter navigation stability

New-word foreground, optional underline and active-cue background are drawn by `TranscriptLayoutManager`. Painting invalidates display only and must not edit `NSTextStorage` from layout or scroll callbacks. Base font changes still use text attributes. Native text selection, wrapping and glyph layout remain managed by TextKit. Follow requests depend on document/cue, explicit resume, viewport dimensions and insets, and text size category; changing estimated content height alone must not cancel or restart an in-flight movement.

Both physical chapters and legacy virtual parts use a dedicated sheet List built from an immutable opening snapshot with stable IDs. Playback position updates do not rebuild the presented rows. Selection resolves the chosen ID against the current item before navigation; closing without selection leaves playback unchanged.

## Phrase level cooldown (2026-10-19)

Store an optional `levelChangedAt` on each dictionary entry. Legacy entries have no reliable transition history: translation timestamps describe a different event, so missing dates are backfilled once with the current time. Freshly added phrases are immediately available for first practice. Level changes from answers, preview and manual editing reset the clock, with transactional rollback and Undo restoring the old date.

New rounds filter by the current level's user-editable cooldown (24/72/96 hours for levels 1/2/3). An unchecked-by-default “Ignore words cooldown” option bypasses selection filtering for that session. Retries and resumed rounds retain their selected membership. Settings are local UserDefaults preferences; transition dates travel in dictionary backups as an optional, backward-compatible field. Level 4 remains excluded.

## Optional word timings refine phrase playback without changing reader cues

Timed book tracks may reference a schema-v1 word-timing JSON sidecar through optional `wordTimings`. Bind it to track ID, normalized parsed subtitle text and exact audio SHA-256, validate every token and local finite ordered time, and preserve explicit zero-duration tokens. Keep ordinary cue text/highlighting for reading. Selection audio uses the first and last selected spoken-word boundaries only when every selected spoken word has a usable duration; otherwise label the existing cue range Play context. Never interpolate speech timing from character/word counts or infer timing for untimed full-book TXT.

Update phrase audio attaches validated sidecars to an existing book with immutable source/track/media identity, completion and progress. Publish uniquely named files before updating model references; a failed save restores track/dictionary values and removes the prepared files. An interruption before the save can leave unreferenced sidecars but cannot replace old media or timing references. Resolve saved selections conservatively within their recorded first cue, using a saved precise range to disambiguate repeated occurrences; ambiguous old ranges remain unchanged. New selections and successful explicit updates persist refined audio bounds through the existing dictionary backup fields. A bounded, file-revision-keyed document cache avoids parsing chapters on playback ticks. Word-level alignment improves granularity but does not certify acoustic accuracy.
