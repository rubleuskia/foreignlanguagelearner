# Architectural and product decisions

## Paid cloud backend proposal (2026-10-30; not adopted)

[The paid cloud backend plan](../docs/PAID_CLOUD_BACKEND_PLAN.md) proposes shared account identity, Apple-verified subscription entitlements, server-operated AI translation with durable usage accounting, and later account-authorized alignment. It recommends independent billing/translation deployment so the existing alignment benchmark gate remains intact. Tariffs, quota periods, account recovery policy, BYOK migration and retention remain open. This is a planning reference, not a replacement for the current local-first/BYOK or anonymous alignment-test decisions, and does not authorize implementation or deployment.


## System playback ownership and reader controls (2026-10-29)

All audio uses the shared PlaybackController integration with MPNowPlayingInfoCenter and MPRemoteCommandCenter. The most recently played controller owns the app's system media session and pauses the previous owner through its coordinator. Pausing retains the session for remote resume; closing clears it only for its owner and does not deactivate another player's audio session. Register remote commands and audio interruption/route notifications once per app process, routing to a weak current owner. Book commands enter BookPlaybackController so playback intent, chapter progression and seeks stay consistent. Clip metadata and remote scrubbing use a zero-based clip timeline while the player retains source-file times. Publish actual playback rate, elapsed time, duration and human-readable book/chapter or phrase metadata. iOS controls presentation on Lock Screen, Control Center, Dynamic Island and compatible widgets; no widget extension or duplicate Live Activity is added.

A shared local reader.font-scale preference provides 75–175% text sizing in 12.5% steps in both reader implementations, composed with the system Dynamic Type size. Restyling waits for text selection to finish, keeps the visible passage when following is off and invalidates the audio-follow layout when needed. Compact-height phone layouts use a horizontal player and hide secondary vocabulary/tutorial chrome to preserve reading space; accessibility text sizes retain the vertical player. Practice reveal remains optional through a large accessible hint button and is also available by tapping the card; the translation region can hide the answer. Revealed cards display swipe direction hints alongside the existing answer buttons.

## Activity snapshots refresh explicitly (2026-10-28)

Activity renders an immutable, timestamped snapshot. It does not poll or reread the database on foreground activation, tab returns, chart selection or period/language changes. The first request loads a versioned snapshot from the app’s private Caches/Activity/statistics-v1.json; only a missing, corrupt or incompatible cache causes an initial rebuild. A native pull-to-refresh from the top of the screen explicitly fetches current data in the background and replaces the snapshot. A last-updated label and gesture hint make staleness visible. Recorded training and reading history continues to save as before.

A dedicated actor owns the source snapshot and a bounded 96-entry in-memory cache of prepared reports keyed by canonical language, normalized period start and calendar/timezone/locale. SwiftData reads, JSON decoding/writing, word deduplication, language discovery and all history aggregation stay off the main actor. Report payloads contain only scalar totals, at most 31 chart buckets (23–25 for a DST day), three level counts, ten recent phrases and a day set. The dashboard no longer observes entire book/dictionary queries or recomputes history-derived values in its body. Source-language discovery uses projected background fetches; per-word JSON key encoding and repeated language canonicalization are removed.

An explicit refresh clears prepared reports only after a successful replacement. Concurrent requests share their in-flight load; a refresh waiting on an initial disk read still performs a fresh database read. Failed refreshes retain the last usable snapshot in memory and on disk. Cache files are disposable derived data, excluded from portable backups, and write failure does not block displaying successfully read statistics. No persisted learning/history schema, metrics or backup contract changes.

## Local activity history and counting (2026-10-28)

Activity is a fourth native tab with a language filter shared with Dictionary/Practice. Unlike training availability, its selector also includes historical activity languages after source deletion. Periods use the current device calendar/timezone with Monday-based weeks. Charts show hourly reading-word buckets for a day and daily buckets for weeks/months. Comparisons use the same elapsed portion of the preceding period. The calendar marks any recorded reading, audio or phrase-level change; a streak can end yesterday while today is unfinished.

New words are distinct canonical-language/form pairs, assigned to the earliest existing reading-knowledge date; they describe completed reading, not proven recall. Phrase promotions and reaching level 4 are distinct phrase counts within the selected period. A phrase can generate multiple promotion events, shown separately, and appears in one highest-attained-level lane. Manual promotion and preview marking-known count and are disclosed. Demotions record practice activity but do not inflate advancement; undo marks its event reverted in the same save as restoring the level. No phrase history is guessed from current levels or legacy last-change timestamps.

The additive SwiftData UserActivityEvent model stores level transitions and growing per-reader-session/day time records, independently of source models so deletion retains history. Level capture shares the existing transaction save and rollback. Time samples monotonic wall time each second while a reader is foreground or its player is actually playing in the background, never playback positions or playback-rate-adjusted duration. A foreground open reader counts as reading, including ordinary pauses. Samples over five seconds or inconsistent with the wall clock are excluded as suspension/clock changes. Foreground/audio overlap counts once; midnight samples split by local day. Saves flush every fifteen seconds and at scene changes/disappearance; unexpected termination can lose the final unflushed seconds.

Library backup v1 gains optional validated activity records with stable UUIDs; time merges by maximum duration for the same session/day and undo tombstones merge by logical OR. Other identity fields must match. Old backups do not invent or clear local history. Dictionary-only backups keep their existing dictionary/reading scope. No cloud analytics or service is added.

## Book overview, progress and local cover policy (2026-10-28)

Library opens a book overview before its reader. Continue delegates to the existing reader adapters and never changes the last explicit-Play timestamp. Opening a chapter from the overview selects its saved local offset; the existing in-reader chooser still explicitly restarts a chapter. Overview progress distinguishes completion-weighted book progress from chapter saved playback position. Read/unread counts describe unique forms in completed text in this book, while new/studied counts use accumulated knowledge across its language. Saved phrases remain a separate metric; their bar represents this book’s share of saved phrases in that language, not a percentage of word mastery.

Two defaulted SwiftData strings store a normalized local cover filename and a stable bundled-cover name. Existing records use `cover-books`. Every chapter inherits the book image; there is no per-chapter artwork override. Six compressed JPEGs ship offline. ImageIO normalizes uploads/ZIP images to JPEG with orientation applied and a maximum edge of 1,200 pixels; encoded inputs are limited to 16 MiB. A small evictable decoded-image cache avoids repeated decoding in chapter lists.

Raw and strict ZIP imports accept image files whose basename is case-insensitively `cover`. Shallower paths take precedence (root covers first), then paths sort lexically. Other strict-package validation is unchanged and no external manifest field is added. Corrupt/oversized selected covers fail before publication. Original staged cover data remains available while retrying or changing cover choice; only the selected normalized cover is moved by the existing transaction. Resource replacement keeps the current cover. Library-state backups add optional validated bundled-cover metadata, preserving older-backup compatibility; user/ZIP image bytes stay in separately imported book assets.


## Continue Reading follows explicit playback (2026-10-27)

Each book stores the time of the last user Play tap. Continue Reading shows the unfinished book with the newest such event, regardless of playback position or import order. Seeking, opening a reader, automatic chapter transitions and passive progress saves do not change this order. Old libraries without play timestamps continue to use the previous saved-progress selection until a book is played. The timestamp is optional in library-state backups so older files remain readable.


## Interface language (2026-10-27)

The app interface defaults to Russian and offers Russian and English in Settings. This preference is independent of the source language of books and dictionary entries; translations and explanations still target Russian. SwiftUI locale changes at the app root so ordinary interface strings update without restarting. Saved book text, phrases, user notes and editable OpenAI prompts are content and are never translated when the interface changes. The preference is an optional typed field in library-state backup settings; older backups preserve the device's current interface language.


## Six source languages with language-bound learning

New books support English, French, Spanish, German, Italian and Polish; translation and explanations target Russian. The app's canonical registry is independent of Apple Translation availability. Supported regional tags group by their base language (case and underscore insensitive); unrelated historical tags remain separate and readable. Existing book/entry metadata and portable reading-history tags are preserved. Tokenizer v1 semantics and timing/package versions remain unchanged.

Dictionary and Practice share `source-language.active.v1`; the new-book preference is separate (`source-language.new-book.v1`, initially Polish). Filter choices come from languages of books currently in the library, including books with no dictionary entries. When there are no books, saved entry languages remain selectable so orphan entries stay accessible. A single available language appears as a fixed flag and label, without a dropdown. The selection automatically resolves to an available language after books change. Screen selection never changes saved data. Dictionary entry language, rather than linked-book language, determines groups. All list/level/readiness/learning pools are scoped before other filters. An open practice sheet captures its source language and labels it throughout the round.

Unfinished training is stored as a language-to-round map under the existing checkpoint key. Rounds optionally encode their language for additive compatibility. Legacy rounds migrate only when every referenced entry exists and belongs to one language; invalid/mixed rounds are discarded with a recovery message while card levels remain. Library backup v1 adds optional `rounds` and typed language preferences, retains its legacy `round`, and merges validated language checkpoints without overwriting unrelated local rounds. Book restore matching also checks canonical language. UUID dictionary conflicts still require identical text and original language metadata.

The alignment API and local batch tool require lowercase base codes `en/fr/es/de/it/pl`. Language is part of the existing canonical request/idempotency input and the worker specification; new worker manifests repeat it and finalization rejects mismatches. Old manifests without the additive field remain supported. The single-file CLI retains its documented Polish default, now prints the selected language, and rejects English-only models for other languages. Infrastructure quotas, authentication and deployment gates are unchanged. Mocked six-language contract tests do not establish audio timing quality; the benchmark gate remains open for all six language rows.


## Progressive books and first-use guidance (2026-10-25)

- Text and audio are independently optional library resources. Empty filenames represent intentional absence; no placeholder media or fake track is created. Existing single-file/video records retain their adapters. Defaulted resource revision, UTF-16 reading anchor and historical language-lock fields are additive SwiftData fields. Untimed full-text reading restores its anchor independently of playback; reading completion keeps its existing explicit/duration-based semantics. Replacing resources must not unlock a language already used for accumulated reading knowledge.
- One Add book wizard previews resources before import. TXT UTF-8, a playable audio file, raw audio ZIP with optional text, and strict manifest packages share the staged import service. The strict external package schema is unchanged: partial local books do not produce a pretend valid strict package. Raw ZIP subtitle files are not linked by filename similarity. Existing SRT/VTT/video import remains a secondary option.
- Resource updates publish a uniquely named generation inside the same book directory, journal before moving files, save model references through the existing main context and restore explicit book/dictionary snapshots on failure. Recovery distinguishes referenced and unpublished generations, cleaning obsolete known resources only after success. Whole audio replacement assigns fresh track identities and clears old card audio bounds. Text replacement resets text position, dependent synchronization and completion; historical studied forms, card text, translations and levels stay.
- Attaching synchronization requires a strict package and byte-identical recordings in the previewed order, plus matching normalized full text when already present. Track identities, playback and valid manual phrase ranges stay. Word-timing sidecars are remapped to the verified existing track identities; obsolete cue indices are cleared so a different segmentation cannot reinterpret saved cards. Legacy single-file audio may be promoted to a physical track only after the same verification.
- Onboarding uses explicit, locally persisted per-step completion, a global skip, a visibility preference and a reset generation. A step is not completed merely by presentation. Reset affects tutorial history only and preserves the enabled preference. Contextual popovers are limited to the relevant visible screen; guide and settings remain available. No analytics or backend was added.
- The optional example contains original English text and narration synthesized locally by the device. An unavailable or timed-out device voice falls back to a readable text example. It creates no dictionary or studied-word records. Translation still follows the existing Russian-target language-pack and explicit cloud opt-in boundaries.
- Library-state JSON adds optional reading-anchor and historical language-lock fields; absent fields preserve existing values on older restores. Audio-only fingerprinting uses ordered recording hashes instead of requiring a transcript. Local resource-generation revisions are not portable and are not restored from another device.

## Practice settings are separate from app configuration

Phrase cooldown intervals belong to a dedicated Practice settings screen reached from the Practice tab. General Settings contains translation/API configuration, prompt customization and diagnostics. The extraction preserves the existing UserDefaults keys, interval validation and explicit Save cooldowns action; leaving without saving discards edits. Round setup points learners to Practice settings.

## Practice card actions beside their content

Practice preview and revealed-answer cards place the translation editor directly beside the translation as an icon-only action, and original copying beside the visible source text. Translation copying and source-context copying are omitted from these cards. The original copy action and audio controls remain hidden until the original is shown. Playback sits below the original, with a compact word/phrase menu, speed control and visible Edit audio action. This action reuses the existing boundary editor and its validation, without changing ranges, learning rules or dictionary long-press controls.

## Native Glass navigation with editorial reading

Library, Dictionary and Practice are peer destinations in a native TabView, each with its own navigation stack. Practice presents the existing learning session, preserving its resumable state machine. Recovery and automatic translation remain attached to the app root so tab selection does not cancel them. Readers hide the tab bar and retain chapter controls in a floating player; manual completion is available in a reading-actions menu with its existing confirmation.

Primary actions use system Liquid Glass on iOS 26, with bordered prominent native controls on iOS 18. Secondary actions use a lower-emphasis capsule. Content uses semantic system backgrounds; glass is confined to controls and floating panels. SwiftUI supplies appearance and accessibility adaptations rather than custom blur or animation.

Reading text uses the system serif design at a 21-point default, UIFontMetrics-scaled typography and paragraph spacing. iPad text is limited to a comfortable measure through text-container insets, while interface controls keep system sans serif. Typography attributes are reapplied after document replacement and Dynamic Type changes, without editing source text or its UTF-16 selection/audio ranges. Reading vocabulary and advanced settings are disclosed on demand. No persistence schema, service boundary or learning algorithm changes are part of the redesign.

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

Untimed text is aligned outside the app using the local `tools/subtitle-aligner` utility. DRM-free EPUB sources first pass through a separate standard-library extractor following the OPF spine. It writes reviewable text sections and an index with EPUB hash, source paths and skipped-document reasons. Publisher-specific cleanup is opt-in (`wolne-lektury`); extracted sections never automatically imply audio boundaries. The alignment input remains verified UTF-8 text, and iOS still imports TXT/SRT/VTT. Guided alignment targets 20-second passages, using rough-transcription anchors, after the 60-second target caused local drift in long Polish recordings. Sparse matches can still create longer passages and a gap over 180 seconds fails. Review output can retain zero-duration words but is explicitly flagged rather than pretending timing is accurate.

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

Ordinary automatic translation uses Apple Translation for explicit Translate Again/Force/Retry,
legacy pending-entry recovery, dictionary imports without translations and source-language changes.
Source-language pickers also use Apple language availability. These remain supported offline-capable
workflows. The unreachable legacy word-by-word translator has been removed. Contextual translation
uses OpenAI Responses API structured output so one request resolves the selected expression
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

The retired Polish Wiktionary definition lookup has no UI or production caller and is removed,
including its parser, coordinator and write-only error logging. The SGJP resolver and compressed
pack existed solely to provide fallback lemmas for that lookup, so they and their exclusive pack
builder are removed too. Reading vocabulary counts surface forms and has never depended on SGJP;
contextual lemmas come from the current cloud analysis. SQLite remains required by VocabularyIndex.
Existing installed morphology files are left untouched; no startup deletion or store migration is
needed. Git history retains the retired implementation.

Persisted WordHelpItem and PolishDictionaryResult shapes, including optional lemma references,
remain in the model for SwiftData and JSON v2/v3 compatibility. Historical Polish lookup diagnostics
retain their Codable shape and a read-only adapter for backup export. No legacy result, attribution,
translation origin, status or backup field is dropped. See docs/LEGACY_TRANSLATION_AUDIT.md for the
call-path audit and retained functionality.

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

Detailed word explanations are a second, explicitly requested level of Meaning in context, shared by the selection preview, dictionary card and revealed learning card. Expanding a word opens content in place, not a new screen. Only one row expands at a time; cancellation and failures never replace the concise translation. The dedicated structured response contains a simple definition, contextual meaning, and one or two illustrative phrases with translations. It uses the existing cloud opt-in, Keychain credential and model selection, with a separate configurable word explanation prompt, independent of the concise-translation prompt (see the 2026-10-25 decision).

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

Cooldown interval editing lives in app Settings, with draft values committed only by Save cooldowns. Existing UserDefaults keys and defaults remain unchanged. Exercise setup exposes only the session override; unsaved global edits never affect practice selection.

## Optional word timings refine phrase playback without changing reader cues

Timed book tracks may reference a schema-v1 word-timing JSON sidecar through optional `wordTimings`. Bind it to track ID, normalized parsed subtitle text and exact audio SHA-256, validate every token and local finite ordered time, and preserve explicit zero-duration tokens. Keep ordinary cue text/highlighting for reading. Selection audio uses the first and last selected spoken-word boundaries only when every selected spoken word has a usable duration; otherwise label the existing cue range Play context. Never interpolate speech timing from character/word counts or infer timing for untimed full-book TXT.

Update phrase audio attaches validated sidecars to an existing book with immutable source/track/media identity, completion and progress. Publish uniquely named files before updating model references; a failed save restores track/dictionary values and removes the prepared files. An interruption before the save can leave unreferenced sidecars but cannot replace old media or timing references. Resolve saved selections conservatively within their recorded first cue, using a saved precise range to disambiguate repeated occurrences; ambiguous old ranges remain unchanged. New selections and successful explicit updates persist refined audio bounds through the existing dictionary backup fields. A bounded, file-revision-keyed document cache avoids parsing chapters on playback ticks. Word-level alignment improves granularity but does not certify acoustic accuracy.

Follow audio resolves contiguous layout through the destination cue and lays out its viewport before clamping the scroll target. If UITextView still exposes an older, smaller content height, raise it to the measured TextKit extent. Keep follow requests keyed by cue/document/viewport rather than estimated content-size changes, so scroll animations do not restart during lazy layout.

Phrase cards display remaining cooldown as a render-time snapshot in days/hours/minutes, rounded up to a whole minute. They use the same saved transition date and current global intervals as round selection, without a periodic timer; level 4 has no countdown.

## Manual phrase audio ranges take precedence

Store optional manualAudioStart/manualAudioEnd as a paired absolute range in track-local seconds on each dictionary entry, separately from automatic audioStart/audioEnd. Playback uses a valid manual range before resolving word timings; invalid overrides fail closed. Word-timing updates may refine automatic bounds but never overwrite manual bounds. Reset clears the pair after Save. Editing is a draft with preview and cancellation, supports fractional earlier/later shifts on either boundary, and rejects nonfinite, inverted, negative or out-of-track ranges. Dictionary backups carry the optional pair; old backups omit it. Restore snapshots include both fields. The shared editor is available from both dictionary and learning cards.

## Dictionary review readiness and round results

Dictionary readiness counts, the Ready to repeat filter, and Quick start require both learning eligibility (including a saved ready Russian translation and a level below 4) and an expired cooldown. The filter combines with the selected level; Quick start uses up to 10 ready phrases across all levels, lower levels first, and opens the existing preview. Like Start round, it replaces an unfinished checkpoint. Dictionary readiness refreshes every 30 seconds.

Capture starting levels before preview and retain them in the round checkpoint so completion cards show the net starting → current level, including preview changes and retries. Undo restores the round and entry together. Old checkpoints omit the transition rather than guessing. Completion shows only this round's cards, including its preview; other learnt phrases remain accessible in the dictionary.


## Per-round retry limit, explicit key checks and duration-weighted reading (2026-10-25)

Count wrong answers per entry within a round. At four errors, a later correct answer completes the entry without increasing its current level; wrong answers still follow the existing demotion rule. Counters are optional checkpoint fields for backwards compatibility, survive resume, and roll back with Undo. A new round starts fresh counters.

Recover interrupted Apple translations only when both language models are installed. Missing downloads become needsDownload and require an explicit retry; recovery never requests preparation UI. Clear the session configuration when a job finishes so an idle session is not reactivated on foregrounding. Settings key validation sends a small, non-stored Responses request with no reader content and the selected model, checking authentication, model access and quota. It does not save a draft key or enable cloud translation.

For new timed selections only, save the containing sentence's automatic audio bounds separately from the selected range. A selection crossing sentences includes all intersecting sentences. Each mode has independent optional manual bounds, editing, reset, and backup fields. Existing entries have no sentence range and retain their playback behavior; no backfill or migration derives new ranges for them. Exact word timings are preferred; otherwise use actual cue bounds, without guessing word timestamps.

Reading fraction equals completed valid chapter audio duration divided by total valid chapter audio duration, using physical tracks or legacy virtual parts. A whole-book completion is 100%; no chapters/duration yields 0% otherwise. Playback position does not affect this metric.


## 2026-10-25 — Natural chapter completion and audio editing

- An audiobook track's natural end reports the completed track before advancing. The reader serializes automatic reading-vocabulary completion through the existing prepare/complete transaction, showing errors rather than silently losing the mark. The final track is included; seeking or choosing another chapter never marks an unfinished chapter read.
- Explicit chapter choice starts its audio and transcript at the beginning, including reselecting the current chapter; initial book opening continues to restore saved playback position.
- Automatic selected-word/context and whole-phrase playback adds 0.5 seconds before and after the resolved source range, clamped to the source media. Padding is applied at resolution, leaving stored timestamps and alignment matching exact, avoiding repeated padding after backup or timing updates. Manual overrides are exact and receive no padding.
- Audio editing has two handles on a shared timeline, snapping dragged boundaries to tenths of a second with at least 0.1 seconds between them. The initial scale covers the phrase plus five seconds on either side; whole-track and zoom controls expose the full legal range. Existing numeric adjustments remain available in a collapsible section so preview and reset are visible alongside the sliders.
- Active playback holds the iOS idle timer disabled so synchronized text stays visible. A weak registry of players and observed playback state release it on pause, end, interruption or player closure, while respecting another active player.


## 2026-10-25 — Word explanation prompt customization

The detailed Meaning in context request has its own Settings editor, with explicit Save and Reset to Default, trimmed nonempty input and the existing 8,000 UTF-16-unit prompt limit. Store overrides locally and read the effective prompt at the beginning of each request; the same snapshot goes into the request and cache key. Prompt version v2 invalidates the previous default results. Existing displayed explanations remain until a new request is made.

The default requests 1–2 complete, natural sentences (aiming for 8–20 words each) and full translations. Each demonstrates the same word sense in an independent everyday situation, without quoting, paraphrasing, continuing or retelling the source or reusing its characters, events or distinctive details. Each example also differs from the other. Editable teaching instructions are followed by mandatory input-as-data and structured-response rules; the strict JSON schema remains fixed.


## 2026-10-26 — Library state backups without book assets

The Library toolbar owns Backup Library and Import Library; Dictionary no longer exposes transfer controls. Existing dictionary JSON v1–v3 import modes remain available from the Library menu. Library backups use `foreign-language-learner.library`, schema 1, capped at 128 MiB, embedding the existing validated dictionary v3 payload and adding book state, typed allowlisted settings, a valid resumable learning checkpoint and at most 200 validated word explanation cache records. Include settings for model, cloud analysis, both prompt texts and three level cooldowns. Never export the Keychain API key, arbitrary UserDefaults, book text/audio/subtitles/word timings, or rebuildable indexes. Saved phrase context remains part of the dictionary payload. Invalid stale training checkpoints referencing deleted entries are omitted.

A book fingerprint hashes normalized full source text plus ordered track IDs and durations rounded to milliseconds (legacy media uses its transcript segments and single duration). It does not use title, UUID, local paths or alignment files. Changing only title or timing sidecars does not change identity; a different transcript or audio layout requires the matching edition. Restore retains the newly imported book's local UUID and physical-file metadata, restores the original title/date/language, completion flags, part structure, active track and playback positions, and remaps imported dictionary source/local-source IDs. Match exact original UUID among equal fingerprints when available; otherwise require one unambiguous local candidate and a one-to-one mapping. Never guess among duplicates or silently drop unmatched book progress. Reimport books before restoring the backup; partial library restoration and pending unmatched states are not supported in v1.

Preview explains overwrites and required book imports. Missing/ambiguous/incompatible books and dictionary identity conflicts block Apply; revalidate portable data and local matching at Apply time. Unrelated library/dictionary records stay local and reading knowledge merges under existing earliest-date semantics. Dictionary, reading vocabulary and book-state mutations share the existing SwiftData transaction. Prepare the cache file before committing and restore it on failure; settings/checkpoint apply only after a successful model save. This is rollback-safe for reported save failures, not a cross-store crash transaction between SwiftData, cache files and UserDefaults. A restart/reimport can reapply the idempotent backup. Cached explanations are reloaded by the live cache actor after import.

## 2026-10-28 — Keep repeated UI updates independent of transcript preparation

Audio controls in dictionary details, selection translation, practice and the boundary editor resolve sources from immutable value snapshots on a detached worker. Snapshot identity includes source text/ranges, manual overrides, source resources, resource revision and timing-sidecar filenames; it excludes translations, notes, playback positions and completion flags. SwiftData objects remain on their owning executor. Reuse the completed result for an unchanged request, hide stale controls while a different request loads, and discard results from cancelled presentations.

Transcript reading/parsing in the book reader and construction of legacy reader documents run on workers when the resource/chapter changes, rather than on playback updates. Prepared word-explanation rows are tied to their actual text/context/language input, independently of disclosure expansion. Library search owns its local state below dictionary phrase-count aggregation so keystrokes do not regroup all saved phrases. Saved audio selection lookup searches the saved cue plus enough following words to complete a cross-cue selection, preserving ambiguity and exact-range rules without scanning the rest of the chapter.


## Audio-session work and player callbacks (2026-10-29)

Playback category changes and audio-session activation/deactivation run on one shared actor, away from the UI executor, because synchronous media-server calls can stall. Controllers publish play intent immediately and wait for activation before allowing seeks or rate changes to start audio. Pause, close and file replacement invalidate the activation generation; late success or failure cannot restart playback or alter a newer presentation. Now Playing ownership follows play intent immediately, so system Pause also cancels a pending start; closing another controller must not deactivate the current owner.

Periodic time, end and seek callbacks enqueue UI-executor tasks before accessing controller/player state. They retain item/seek generation checks, allowing end-of-track handlers to replace items after leaving AVFoundation callbacks. Closing an unopened player does not deactivate the shared session. Translation and dictionary saving remain independent of audio preparation and playback.
