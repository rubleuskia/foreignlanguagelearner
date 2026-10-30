# Project changelog

## 2026-10-30 — Paid cloud backend implementation plan

- Add [the paid cloud backend plan](../docs/PAID_CLOUD_BACKEND_PLAN.md) covering account identity, Apple subscription verification, server-operated translations, durable request/usage accounting and later integration with the existing alignment backend.
- Record proposed API/data boundaries, rollout order, failure/recovery cases and unresolved tariff, quota, BYOK and retention choices. Link the plan from the alignment architecture and future-work backlog.
- Documentation only: no implementation, deployment, subscription configuration or tariff approval. DECISIONS.md indexes the proposal without replacing current decisions. No adopted architectural/product decision, shipped workflow or project overview changed; PROJECT.md is unchanged.


## 2026-10-30 — Horizontal transcript scrolling

- Timed transcript lines in the playback reader remain on one line and can be scrolled horizontally; playback follow keeps the active cue's beginning visible. Full-text reading keeps its existing wrapping.
- No architectural/product decision or project-overview change was required.

## 2026-10-29 — Responsive audio during selection translation

- Move synchronous audio-session setup and teardown off the UI executor so tapping Play in a selection's dictionary/translation popup cannot block translation rendering and other interface actions while the media server responds. Playback starts only after session activation; pause, close and source replacement invalidate pending starts and errors. Rate changes and seek completions cannot bypass activation.
- Enqueue player time, end and seek callbacks on the UI executor before reading or changing playback state, retaining stale-event checks and safe chapter transitions. Repeated play requests coalesce while activation is pending; explicit Play still resumes after a system interruption.
- Add a delayed translation UI fixture and cover selecting text, adding to the dictionary, playing audio before translation completes, saving the result, closing the popup and resuming the reader. Unit coverage holds audio activation open and verifies responsive pause/close, stale-result rejection, failure/retry and seek/rate gating.
- Verification: all 241 unit tests and the selection translation/audio and natural chapter-transition UI scenarios pass on the iOS 26.5 iPhone 17 Pro simulator after integrating the current Now Playing controls. Audio-boundary editing UI also passed before integration. The original physical-device stall has not been measured or reproduced with a device stack trace.
- DECISIONS.md records audio-session execution and callback handling. No project purpose, supported workflow or major boundary changed, so PROJECT.md is unchanged.

## 2026-10-29 — System audio controls and easier reading/practice

- Publish book/chapter and phrase playback to iOS Now Playing for the Lock Screen, Control Center and supported Dynamic Island media surfaces. System play/pause, ten-second skips and scrubbing control the current player; chapter commands use the book coordinator and phrase timelines stay relative to their clip. Only one app player owns the session. Interruptions and disconnected headphones pause playback.
- Tap the practice card to reveal the answer and tap its translation to hide it again. Show a hand/tap hint before reveal and explicit left=Right, right=Wrong swipe hints afterward; answer buttons and undo remain available.
- Use compact landscape playback panels in both readers, reduce the book mode selector spacing and hide secondary vocabulary/tutorial chrome in compact height. Add a persistent Aa text-size menu in both readers, retaining Dynamic Type, selection and audio following.
- Verification: all 237 unit tests and 16 targeted UI scenarios pass across simulator runs on iOS 26.5 / iPhone 17 Pro, including system metadata, clip-relative remote seeking, playback ownership, interruptions, card tap/swipe/undo, both landscape readers, persistent font size and Russian accessibility text. Dynamic Island presentation and third-party media widgets still need a physical-device check.
- DECISIONS.md records the playback ownership and reader preference policies. No project purpose, supported workflow or major boundary changed, so PROJECT.md is unchanged.

## 2026-10-28 — Audit repeated work across interactive screens

- Dictionary translation/meaning/note editing, selection translation, practice audio and boundary sliders no longer read/parse transcripts or resolve aligned audio inside view rendering. Resolve immutable source snapshots on a worker and reuse results until actual audio inputs change, including manual bounds, resource replacement or new timing sidecars. Boundary drags also skip repeated audio-session teardown once the preview is closed. Playback positions and unrelated edits do not invalidate them; cancelled loads cannot install stale controls.
- Build legacy reader documents once per chapter and move both book-reader text/subtitle loads off the UI executor. Cache prepared word-explanation rows across disclosure changes. Isolate library search from dictionary-wide phrase grouping.
- Bound saved-selection regex searches to the original cue and enough subsequent words for cross-cue phrases, retaining whitespace, repeated-phrase and legacy-padding behavior.
- Verification: all 235 unit tests and eight targeted UI scenarios pass on the iOS 26.5 iPhone 17 Pro simulator. A 30,000-cue chapter resolves 100 saved selections in about 10 ms in the synthetic benchmark. Physical-device hang durations have not been measured.
- DECISIONS.md records the execution and invalidation policy. No project purpose, supported workflow or major boundary changed, so PROJECT.md is unchanged.

## 2026-10-28 — Responsive practice translation editing

- Give the practice translation editor its own draft and presentation state. Opening it and typing no longer invalidate the entire practice card, which synchronously resolves phrase audio and loads/decodes source transcripts. Skip audio teardown when no audio is open.
- Preserve Save/Cancel behavior in preview and active rounds; display save failures inside the editor and retain the draft for retry. The editor can expand to a large sheet above the keyboard.
- Verification: 32 learning unit tests and two UI scenarios pass on the iOS 26.5 iPhone 17 Pro simulator, including typing, cancelling, reopening, saving and continuing a round on a card with audio. Physical-device hang durations have not been measured.
- No architectural/product decision or project overview changed.

## 2026-10-28 — Cached activity statistics with manual refresh

- Stop the Activity screen’s 15-second polling and foreground-triggered database reloads. Reuse a persistent derived snapshot across launches and prepared in-memory reports across navigation. With no usable cache, build the initial snapshot once. A long pull down from the top explicitly refreshes the statistics; a timestamp and gesture hint explain when the displayed snapshot was captured.
- Move language collection, database reads, decoding, aggregation, chart buckets, level counts, recent-phrase selection, calendar days and streak preparation off the UI executor. The screen renders bounded ready-to-display values without scanning managed dictionary entries or the activity history on each redraw.
- Preserve the displayed results during refresh and after refresh failures. Coalesce concurrent loads, invalidate prepared reports after a successful explicit refresh and fall back to rebuilding an unavailable/corrupt cache. Canonicalize each source language once during word deduplication instead of once per word.
- Verification: seven cache tests and twelve existing activity-history tests pass; dashboard UI coverage verifies frozen results after practice and updates after a long pull. Other day/week/month, language, empty-state and accessibility scenarios pass, as does the Russian iPad dashboard. A 30,000-event fixture exercises 100 prepared-cache reads without re-aggregation.
- DECISIONS.md records the derived-cache and manual-refresh policy; PROJECT.md describes the supported refresh gesture.

## 2026-10-28 — Center the library Continue action

- Move the Continue button below the featured book’s cover and metadata so it spans the full row, with its label and saved-position caption centered. This removes the offset caused by placing the button inside the right-hand metadata column. An explicit icon/text group also avoids the inherited List label layout shifting the caption.
- No architectural/product decision or project overview changed.

## 2026-10-28 — User activity dashboard

- Added a dark native Activity tab with day/week/month navigation, language selection, new reading words, distinct phrases advanced, phrases reaching level 4, time with books, interactive word charts, a monthly activity calendar, a current streak and recent phrase transitions. iPad uses a two-column layout; Russian/English and accessibility text sizes are supported.
- Word counts reuse earliest recorded reading-form dates, deduplicated by canonical source language. Phrase history starts with this update and records practice, preview and manual level changes atomically; cancelled answers do not count. Each phrase appears once at its highest attained level, alongside the number of promotion events.
- Time records wall time with an open foreground reader or actual background audio, counting simultaneous reading/listening once and excluding suspended intervals. No past time or level history is inferred.
- Independent local activity records survive deleting books/phrases and travel in optional library-backup history. Repeated restores merge stable identities, growing session time and undo tombstones. Old backups remain readable; dictionary-only exports retain their existing scope.
- Verification: 221 unit tests and five Activity UI scenarios passed on iPhone; existing tab-navigation regression passed. Twelve activity unit tests and the Russian day/week/month dashboard UI scenario passed on iPad, including screenshots.
- DECISIONS.md records counting, retention, timing and backup rules; PROJECT.md includes the new supported workflow.

## 2026-10-28 — Book library redesign and local covers

- Replaced library rows with image-led dark layouts, blue primary actions and filters, green reading-progress bars, title search and recent/title sorting. Library, Dictionary and Practice remain available.
- Opening a book now presents its overview, word statistics and ordered chapters/virtual parts. Continue uses the existing saved reader position and explicit-Play recency policy. Chapter rows display completed/in-progress/not-started states, local saved time and inherited book artwork; selecting one resumes its own saved position without marking it read. The in-reader chapter chooser keeps its existing restart behavior.
- Added new/studied unique-word counts, saved-phrase counts and distinct read/unread unique forms from completed text. Phrase bars show the book’s share of saved phrases in the same language; no arbitrary learning target or likes were introduced.
- Import offers six bundled offline covers (about 1.24 MiB combined), custom image upload and automatic case-insensitive `cover` image detection in raw and strict ZIP packages. Covers are validated, bounded to 16 MiB input, downsampled to 1,200 pixels and staged with book resources. Existing records use the supplied books-on-table placeholder.
- Defaulted cover metadata preserves existing SwiftData stores; optional built-in-cover metadata round-trips through library-state backups. Custom cover image bytes remain book assets and are not embedded in state backups.
- Added import/image-boundary and chapter-presentation unit tests, navigation/import/accessibility UI coverage, and Russian/English strings. Updated DECISIONS and PROJECT for the new entry workflow and cover policy.


## 2026-10-27 — Russian and English interface languages

- Use Russian as the default interface language and add an immediate Russian/English switch in Settings. Localize navigation, import, reading, dictionary, practice, backup and configuration screens without changing book text or the fixed Russian translation target.
- Center Quick start text in Dictionary and Practice at both interface languages and large text sizes.
- Order listening-screen toolbar actions as Complete, optional source language, then the rightmost ⋮ menu. Full audio replacement remains in ⋮; move the separate phrase-audio timing update there too, removing its standalone toolbar button.
- Show Translate in Context, Add to Dictionary and Copy as matching icon-and-text actions in the text-selection menu, without grouped dividers. Copy keeps the exact highlighted text.
- Choose Continue Reading from the unfinished book whose Play button was pressed most recently, even when it has no saved progress yet. Existing libraries use their saved-progress order until the first Play tap.
- Show each chapter's audio duration in the chapter picker, including virtual parts of older single-file books.
- Show a horizontal progress bar and numeric percentage for each book in Library and its Continue Reading card, replacing the text progress label.
- Preserve the chosen interface language on this device and in new library-state backups. Older backups without the setting keep the device's current choice.
- DECISIONS.md records the interface-language boundary; PROJECT.md describes the updated workflow.


## 2026-10-27 — Book-based language filter with flags

- Show country flags beside source languages in Dictionary and Practice. Offer only languages present in the library's books; a single-language library shows a fixed labelled flag instead of a picker. When the library is empty, retain access to dictionary entries by their saved language.
- Automatically select an available language when books are added or removed. No new architecture or project boundary changed; DECISIONS.md records the selector's book-based availability rule and PROJECT.md reflects the workflow.
- Verification: targeted language-group unit test and Dictionary/Practice UI checks on iPhone Simulator pass; `git diff --check` passes.


## 2026-10-27 — Six source languages and isolated learning groups

- Support English, French, Spanish, German, Italian and Polish for new books with Russian translations. Import uses one registry independent of Apple pair availability, confirms a separately remembered language, honors supported package metadata and rejects unsupported new packages explicitly.
- Add a shared persisted Dictionary/Practice language dropdown. Lists, level/readiness totals, quick starts, previews, retries, learnt reviews and results stay within the entry's own source language; historical groups remain available. An open round keeps its original language.
- Keep independent unfinished rounds per language with conservative legacy migration and recovery messages. Library backups round-trip all valid checkpoints and typed language preferences, preserve orphan-entry and regional metadata, retain unrelated local rounds, and reject cross-language book matches.
- Group supported regional reading-history tags without rewriting old exports or changing tokenizer/timing versions. Retain same-language knowledge sharing and cross-language isolation. Add Italian function-word handling, neutral mandatory prompt text (v5), source hints for selection tokenization, and explicit rollback for book language changes.
- Align backend/OpenAPI/local tools on the six lowercase source codes. Pin language through idempotency, worker input and new result manifests; reject output-language mismatches and English-only local models for other languages. Quotas, authorization and deployment gate are unchanged.
- Verification: 204 Swift unit tests pass; the new dropdown synchronization/empty-group UI check passes on iPhone 17 Pro Max and iPad Pro 13-inch (M5). Unsigned iOS Release build passes. Backend 15 tests, local aligner 26 tests, worker 3 tests and TypeScript/CDK assertions pass. The full existing UI suite was interrupted during development; only the focused new UI checks are claimed here.
- Real-audio quality benchmarks were not run for any of the six release-matrix languages: no matching fixtures/model weights were present. `docs/ALIGNMENT_BENCHMARKS.md` records provenance, measurement and listening requirements; no deployment or merge occurred.
- DECISIONS.md records language normalization, checkpoint/backup compatibility and alignment contracts; PROJECT.md and affected workflow docs describe the expanded supported workflow. Project purpose and local/cloud boundaries are unchanged.


## 2026-10-27 — Multilingual source implementation plan (documentation only)

- Add `docs/MULTILINGUAL_SOURCE_IMPLEMENTATION_PLAN.md` for six book source languages with Russian translations, shared Dictionary/Practice language filtering, isolated counts and training progress, backup compatibility and local/cloud alignment scope.
- This records the approved implementation scope, not shipped behavior. No implemented architectural decision or current supported workflow changes in this documentation step; DECISIONS.md and PROJECT.md will be updated with the implementation.

## 2026-10-26 — Progressive book import and first-use onboarding

- Add a unified book wizard for text, audio, audio ZIP with optional TXT and complete synchronized packages. Text-only books can be read; audio-only books can be played; unsynchronized books open full text directly.
- Add a vertical book resource menu in library rows and both readers. Missing text/audio can be attached to the same book; replacements preview their consequences. Journaled resource generations, explicit rollback snapshots and startup recovery protect existing files and dictionary data. Compatible synchronization packages verify current text and exact audio bytes.
- Keep independent full-text reading positions. Preserve card text, translations, learning levels and historical studied forms on resource replacement while clearing unsafe old audio links.
- Keep partial books compatible with library-state backups: audio-only identities use recording hashes, and optional reading-anchor/language-lock fields preserve text-only progress without changing older JSON decoding.
- Add contextual first-use tips, a help guide, a tutorial toggle/reset, and an optional original locally narrated example. Existing audio/video with SRT/VTT import remains available.
- Verification: 196 unit tests, iPhone onboarding/import UI checks, iPad wizard/text-only reader checks and unsigned iOS Release build pass. Tutorial dismissal is also verified at the largest accessibility text size.
- DECISIONS.md records resource identity, recovery and tutorial policies; PROJECT.md and README describe the expanded workflow. Project purpose and local/cloud boundaries are unchanged.

## 2026-10-25 — Onboarding implementation plan (documentation only)

- Add `docs/ONBOARDING_IMPLEMENTATION_PLAN.md` with the proposed import wizard, partial-book states, safe resource updates, contextual onboarding, implementation sequence and acceptance checks.
- This is a future implementation plan, not a shipped feature. No architectural/product decision or project overview changed; DECISIONS.md and PROJECT.md remain unchanged. Implementation PRs must record the decisions and supported workflows they actually introduce.

## 2026-10-26 — Portable library state backup

- Move the dictionary transfer toolbar menu to Library as Backup Library / Import Library. Keep older dictionary JSON restore, merge and translation-only imports accessible from Library.
- Export a versioned library JSON backup containing dictionary details and learning levels, studied reading vocabulary, book/chapter/part completion and playback positions, an unfinished training round, settings, both prompts and the bounded detailed-word explanation cache. Book text, audio, subtitles and alignments are excluded; the device-only Keychain API credential and rebuildable indexes are not exported.
- On a new phone, import the same book packages first, then import the library backup. Match by normalized source text plus ordered track IDs/durations, independently of titles and local UUIDs. Restore saved states and reconnect dictionary phrase-audio references to the new local book IDs without moving book files.
- Preview missing, ambiguous or incompatible books and conflicting dictionary identities before restoring. Block application until these are resolved; recheck matches at Apply time. Existing unrelated books, entries and studied words are retained. Model changes save atomically and a failed save restores the previous cache and progress.
- DECISIONS.md records the format and matching policy; PROJECT.md and the backup guide describe the new cross-device workflow. Project purpose and major boundaries are unchanged.

## 2026-10-26 — Preserve chapter progress when leaving the reader

- Ignore progress callbacks after playback closes so Back and reopening resume the current chapter instead of saving the teardown position or stale track snapshots. Apply the same live-player guard to the single-file reader.
- Stop the audiobook position observer when its sleep is cancelled; do not refresh from a closed player. Explicit chapter selection continues to start at zero.
- Add regressions for closed snapshots, cancelled observation, and Back/reopen in both readers, followed by explicit chapter selection. This restores the existing progress contract; no architectural/product decision or supported workflow changed, so DECISIONS.md and PROJECT.md need no update.

## 2026-10-25 — Editable word explanation prompt

- Settings now offers a separate Word explanation prompt editor with save, validation and reset to the default. It applies to detailed explanations opened by tapping a word in Meaning in context.
- Default examples are complete sentences (aiming for 8–20 words) in independent situations, with full translations. They must not quote, paraphrase or reuse the source situation or its characters and events.
- Cache keys include the effective word prompt and its version so changing the prompt avoids previous-prompt results on new requests. Structured output and input safety rules remain mandatory.
- DECISIONS.md records the prompt customization policy. Project purpose, supported workflow and major boundaries are unchanged; PROJECT.md needs no update.

## 2026-10-25 — Dedicated practice settings

- Move phrase cooldown intervals out of general Settings into a dedicated Practice settings screen opened from the Practice tab. General Settings retains contextual translation, API configuration, prompt and diagnostics.
- Preserve saved cooldown values, validation and explicit Save cooldowns behavior; update the round-setup guidance to point to Practice settings.
- Update DECISIONS.md and PROJECT.md for the new settings entry point. Project purpose and major boundaries are unchanged.

## 2026-10-25 — Practice preview text and audio actions

- Replace the practice card’s phrase-actions menu with a larger icon-only translation edit action at the right of the translation, and a vertically centered copy action at the right of the revealed original. Remove translation copying and context copying from practice cards.
- Place playback below the original in a dedicated audio panel. Replace the full-width word/phrase segmented control with a compact fragment menu and simplify the playback-speed control. A visible Edit audio action opens the existing validated boundary editor without a long press. Dictionary audio controls remain unchanged.
- Add UI coverage for text-action alignment, answer hiding, copying, fragment switching and explicit editing of independent word/phrase ranges. DECISIONS.md records the updated practice-card interaction. Project purpose, supported workflows and major boundaries are unchanged; PROJECT.md requires no update.


## 2026-10-25 — Native Glass interface and editorial reading

- Introduce permanent Library, Dictionary and Practice tabs, a featured in-progress book, explicit empty-library import actions and a dedicated practice home with quick start and saved-round access.
- Unify primary and secondary actions, grouped form surfaces and chapter states. Use system Liquid Glass controls and floating playback panels on iOS 26, retaining native iOS 18 fallbacks.
- Give both readers serif typography, Dynamic Type-scaled line/paragraph spacing and a comfortable iPad text measure. Preserve transcript text, UTF-16 selection ranges, paint-only word/cue highlighting and follow-audio behavior.
- Move learning copy/edit commands into a phrase menu; source copying is available only while the original is visible. At accessibility text sizes, preview actions scroll with content instead of covering the phrase.
- Move reading completion into the reading-actions menu, reading vocabulary into a disclosure, and advanced prompt/diagnostic tools into disclosures. Keep explicit confirmations, translation settings, audio-boundary precision and learning rules.
- DECISIONS.md records the visual system and navigation; PROJECT.md updates the supported navigation and reading workflow. Project purpose and major data/service boundaries are unchanged.

## 2026-10-25 — Chapter completion and audio boundary controls

- Natural audiobook track completion marks the finished chapter read through the reading-vocabulary transaction, including the final chapter. Manual selection does not mark chapters read and opens the selected chapter at the beginning with the transcript scrolled to the top.
- Automatic dictionary audio gains 0.5 seconds on either side, clamped to its media track. Stored alignment metadata stays exact; manual overrides play exactly as edited and reset restores padded automatic playback.
- Boundary editing offers two handles on one timeline with 0.1-second adjustments, a phrase-focused scale, whole-track view, preview, and existing numeric shifts in a collapsible section.
- The screen stays awake while an app player is playing; pause, completion, interruption and closing playback restore normal auto-lock when no other player is playing.
- DECISIONS.md records these policies; PROJECT.md updates the supported workflow. Project purpose and major boundaries are unchanged.

## 2026-10-25 — Remove unreachable translation and definition services

- Remove the old Apple word-by-word branch from contextual translation and the unreachable Polish Wiktionary lookup/parser/coordinator. Contextual explanation continues through the existing OpenAI service.
- Remove the SGJP resolver, its exclusive pack builder and the unused 36,861,590-byte compressed bundle resource (about 35 MiB). Reading-vocabulary indexing and contextual lemmas do not use this database; existing installed files are left untouched.
- Preserve the reachable ordinary Apple Translation actions, pending-record recovery, untranslated JSON imports and source-language changes. Preserve SwiftData/JSON word-help and cached definition models, optional lemma fields, historical diagnostics and all backup versions.
- Add legacy JSON/diagnostic compatibility and cloud-context refresh regression checks; extend persistent backup/restore coverage to optional lemma references. DECISIONS.md records the retired/retained boundaries; PROJECT.md and README reflect the current workflow. Project purpose is unchanged.

## 2026-10-25 — Training, audio modes and reading progress

- New/Learnt show their totals without a parenthesized review count; Learning/Practising retain the count without “to repeat”.
- Round results contain only the current round and its preview. Four wrong answers for the same entry in one round block promotion on its eventual correct answer; retries continue until correct. Checkpoints and Undo retain the per-entry counter. Existing wrong-answer demotion remains unchanged.
- Startup translation recovery checks installed languages before creating a session, leaving missing downloads for an explicit retry instead of presenting download UI at launch, and clears idle translation sessions. This addresses a possible source of the reported brief bottom popup; reproduction after a long pause still requires device confirmation.
- Settings can validate the entered or saved API key with a small request to the selected model, showing OK or an error.
- New timed dictionary selections retain separate selected-word and whole-sentence audio ranges. Both modes support manual boundary editing and backup/restore; existing entries are not backfilled. Without word timings, cue boundaries remain the fallback.
- Library and book reader show reading percentage weighted by completed chapters’ audio duration, including legacy parts and whole-book completion.
- DECISIONS.md records the changed behavior; PROJECT.md updates the supported workflow. Project purpose and major boundaries are unchanged.

## 2026-10-22 — Manual phrase audio boundaries

- Long-press the audio button in dictionary or learning cards to edit the start/end boundary, move it earlier/later by fractional seconds, preview, save, or reset to automatic timing.
- Persist per-entry manual ranges, prefer them during playback, preserve them during word-timing updates, and include them in dictionary backup/restore with validation and rollback.
- Record the manual-range decision in DECISIONS.md. Project purpose and major boundaries are unchanged; PROJECT.md now mentions this supported workflow.

## 2026-10-22 — Dictionary review shortcuts and round level changes

- Remove the redundant Translation available label; keep translation errors and pending states. Show ready-to-repeat counts in parentheses after each level total, add a combinable readiness filter, and offer Quick start when eligible phrases have finished cooldown. Counts refresh every 30 seconds.
- Quick start opens the usual preview for up to 10 ready phrases, using the existing lower-level-first selection and new-round checkpoint replacement behavior.
- Completion cards include round phrases and highlight their starting → current level. Starting levels survive round checkpoints and Undo; older checkpoints remain readable without invented starting levels.
- DECISIONS.md records these behaviors; PROJECT.md documents the added review workflow. Project purpose and boundaries are unchanged.

## 2026-10-19 — Follow audio reaches distant cues in one action

- Resolve transcript layout through the active cue and its destination viewport before calculating the scroll limit. Synchronize an underestimated scroll extent with measured text geometry so Follow audio reaches the highlighted passage on the first press.
- Added a 2,000-cue regression with noncontiguous layout and stale content height. Existing same-cue deduplication and manual-scroll behavior remain covered. DECISIONS.md records the geometry rule; project scope and supported workflows are unchanged, so PROJECT.md needs no update.

## 2026-10-19 — Remaining cooldown on phrase cards

- Dictionary list cards and phrase details show the remaining days/hours/minutes until repeat, or Ready to repeat when cooldown expires. Completed level-4 phrases have no countdown.
- Calculate from the persisted level-change date and current global intervals during rendering, rounding remaining minutes up. No ticking timer is used. DECISIONS.md records this display policy; project scope and workflows are unchanged, so PROJECT.md needs no update.

## 2026-10-19 — Play selected words using saved alignment timings

- Add optional word-timing sidecars to book imports and local batch publishing. Reader selections, previews, dictionary cards and learning cards use the first/last selected spoken-word boundaries; missing or zero-duration spoken-word timings fall back to clearly labeled Play context.
- Add Update phrase audio to existing books: validate local audio/text identity, attach timing files without reimporting the book, and refine unambiguous dictionary ranges while preserving source IDs, completion and playback progress. Failed saves restore prior metadata.
- Add a cache-upgrade utility and validate the final saved Lalka conversion: 39 tracks, 258,855 token timings, 9,589 zero-duration tokens; new recognition was unnecessary. Real-data selection tests cover a phrase inside a multiword subtitle cue.
- DECISIONS.md records the optional sidecar and update contract; PROJECT.md includes word-level playback and existing-book updates. See docs/WORD_AUDIO_TIMINGS.md for package details and validation limits.

## 2026-10-19 — Inline copy actions in context translation

- Keep each Copy action on the same row as its explanation, overall translation, original or source sentence, aligned at the right edge. Remove the standalone divider that produced an empty Form row. Apply the same layout to dictionary source context.
- Shared content-row layout only; no product or architectural decision or supported workflow boundary changed. DECISIONS.md and PROJECT.md require no additional changes for this fix.

## 2026-10-19 — Global cooldown settings with explicit save

- Move cooldown interval editing to app Settings with draft fields, validation, Save cooldowns and saved confirmation. Existing global values are preserved; leaving without Save discards edits.
- Exercise setup retains only Ignore words cooldown and a pointer to Settings. DECISIONS.md and PROJECT.md describe the corrected workflow; project purpose and boundaries are unchanged.

## 2026-10-19 — Configurable phrase cooldown

- New practice rounds wait 24/72/96 hours after a transition into level 1/2/3, with editable hour values and an “Ignore words cooldown” checkbox on the start screen. New phrases remain available for first practice.
- Preserve transition dates across backup/restore, failed saves and Undo. Backfill existing missing dates with current time because previous level transitions were not recorded.
- Added cooldown boundary, bypass, migration and rollback/Undo regression coverage. DECISIONS.md records the policy; PROJECT.md describes the updated practice workflow.

## 2026-10-19 — Verify manual transcript swipes with audio paused

- Added a dedicated long-transcript UI regression test for play → pause → successive fast manual swipes, highlight toggling without viewport movement, and reverse scrolling while playback stays paused. The scenario passes with the existing scrolling fix.
- Test fixtures and launch-gated DEBUG telemetry only; no additional Release behavior, architectural decision or project scope changed. DECISIONS.md and PROJECT.md require no further changes.

## 2026-10-19 — Stable reader and chapter-list scrolling

- Paint unknown-word colors, accessibility underlines and active-cue backgrounds through a dedicated layout-manager drawing layer without editing text storage during scrolling. Follow requests are keyed to cue/document/viewport changes rather than fluctuating estimated content height.
- Replace updating chapter/part menus with a native sheet list captured when opened; playback ticks and saved positions cannot rebuild its rows or reset its scroll position. Playback continues while selecting a chapter.
- Added regression checks for viewport stability, redundant follow requests and scrolling to chapter 100 during playback. DECISIONS.md records paint-only decoration and stable chapter snapshots. PROJECT.md notes the chapter chooser; project purpose and network boundaries are unchanged.

## 2026-10-19 — Persistent vocabulary index and library counts

- Library rows show new unique word forms for unread books and total unique forms for explicitly completed books, with loading, updating and retry states. ZIP import and book badges count the same TXT-plus-subtitles corpus.
- Cache parsed source vocabularies and update book counters through a word-to-book index; repeated completion preparation does not tokenize the book again. Reconcile the disposable index with primary knowledge on startup/restore and rebuild it on retry.
- Store new knowledge in bounded SwiftData batches together with completion flags. Preserve old individual records, earliest learned dates, atomic restore and the portable v3 format. No separate competing writer was introduced.
- Cache compact occurrence positions and limit new-word decoration to visible text, preserving native selection, cue backgrounds and following.
- Added index/recovery, representative large-vocabulary, 100-book and library UI checks. DECISIONS.md records the implementation choices and deviations from the initial proposal; PROJECT.md includes the library counter workflow.

## 2026-10-19 — Fill practice rounds across learning levels

- Practice rounds now fill the requested size from level 1, then level 2 and level 3 as needed. For example, a 30-word round with 5 eligible level-1 phrases takes 20 from level 2 and 5 from level 3.
- Updated DECISIONS.md for the round selection rule. Project purpose and supported workflow boundaries are unchanged; PROJECT.md requires no update.

## 2026-10-18 — Compact translation copy and animated swipe answers

- Russian translation and Copy now share one dictionary-detail row; long translations wrap without adding a separate copy row.
- After Check, swipe left for Right (green) and right for Wrong (red). The card follows horizontal dragging and exits in that direction before saving the answer; short or vertical gestures return without answering. Reduce Motion uses color and reduced movement. Undo remains available after the answer saves.
- Updated DECISIONS.md for the reversed swipe mapping. Project purpose, supported workflows and boundaries are unchanged; PROJECT.md requires no update.

## 2026-10-18 — Repository contribution workflow and archived review

- Require new chats to begin from fetched main on a dedicated branch, using a separate worktree when another agent owns the checkout and preserving existing changes.
- Preserve the historical alignment-backend review of de8eed6 with an explicit snapshot disclaimer; its findings are not assertions about current main.
- DECISIONS.md records the contribution workflow. Project purpose, supported product workflows and boundaries are unchanged; PROJECT.md requires no update.

## 2026-10-18 — Studied vocabulary from reading

- Chapters and whole books can be marked read once, with confirmation showing the number of new unique word forms. Whole-book completion includes full TXT and available track subtitles; tracks without subtitles contribute only when the whole book is confirmed.
- Read word forms accumulate locally by language, independently of dictionary cards and learning levels, and survive library deletion. Existing completed chapters migrate without assuming full-book coverage.
- Both import workflows preview unique/new/studied word counts. Both readers show live counts and optional new-word coloring while preserving cue backgrounds and native selection. Source language locks after the first reading completion.
- Dictionary backup v3 includes reading vocabulary, restores it without books and merges it atomically with dictionary records. V1/v2 remain supported; translations-only leaves reading knowledge unchanged. Updated JSON schema and backup instructions.
- Added persistence migration, rollback, Unicode, backup and reader UI checks. DECISIONS.md and PROJECT.md now describe the shipped reading workflow; project purpose and network boundaries are unchanged.

## 2026-10-18 — Level-ordered practice and swipe answers

- Rounds now select only the lowest eligible level, capped by the chosen size; higher levels wait until no eligible lower-level phrases remain. Setup shows the current level and actual round size.
- Revealed practice cards accept right/left swipes for Right/Wrong while preserving vertical scrolling and the answer buttons.
- A three-second Undo restores the last answered card, its level and round counters, including from completion. Save failures retain the answered state; a new answer replaces the previous undo.
- Preview now offers Skip to exclude a word from the current round without changing its level or dictionary record. Integrated current main, including resumable training and inline word explanations; Undo updates the resume checkpoint.
- Updated DECISIONS.md and PROJECT.md for the training workflow; project purpose and major boundaries are unchanged.

## 2026-10-18 — Inline detailed word explanations

- Tap a word in the contextual breakdown to expand a plain-language definition, its meaning in the source sentence, and 1–2 typical source-language phrases with translations. One word is expanded at a time in selection previews, dictionary details and learning cards.
- Details load only on explicit expansion, with local loading/retry states; the short translation stays available. Successful explanations are cached across launches for the exact word occurrence, context, languages, model and prompt version. Cache data is purgeable and is not included in dictionary backups.
- Existing serialized breakdowns are mapped conservatively to source occurrences, including repeated words and UTF-16 offsets. Unsupported legacy text stays readable and can be refreshed through the existing contextual translation action.
- DECISIONS.md records the on-demand request and derived-cache design; PROJECT.md includes the new workflow. Project purpose and cloud-consent boundaries are unchanged.


## 2026-10-18 — Resumable word training and level filters

- Preview reveals the answer immediately only for level 1; levels 2–3 require Check before the three preview actions appear.
- Unfinished rounds are checkpointed after the first Right/Wrong and offered again in the dictionary and learning setup. Closing requires confirmation after answers; swipe dismissal is disabled. Each answer still saves its word level immediately.
- Learning progress rows filter the word list by level, with a reset action and empty state; level 4 shows learnt words in the filtered list.
- Training card copy/edit and copy/audio controls share horizontal rows.
- Updated DECISIONS.md and PROJECT.md for the resumable learning workflow.

## 2026-10-18 — PR integration with main

- Integrated the smoother transcript-following changes from main with dictionary training and phrase-audio improvements, retaining both sets of changelog entries.
- No new architectural/product decision or project overview change; DECISIONS.md and PROJECT.md require no further updates.

## 2026-10-17 — Manual dictionary level selection

- Dictionary detail now lets learners select any level from 1 to 4 in Progress. Changes save immediately and update dictionary counts, learnt grouping and practice eligibility. Failed saves restore the previous level and show an error.
- Recorded the manual level override in DECISIONS.md. Project purpose, supported workflow and major boundaries are unchanged; PROJECT.md requires no further update.


## 2026-10-17 — Pre-learning card preview

- Start round now begins with a revealed preview of every selected phrase, including its translation, audio, source context and contextual meaning. The three bottom actions remain visible while scrolling.
- Start learning keeps a phrase at its current level and queues it for the usual Check/Right/Wrong practice after the preview. Move to next level raises its level once and skips practice this round; Mark as known sets level 4 and skips practice. Each action advances to the next preview card.
- Level changes save before advancing, reject stale/double taps and retain the current card on failure. Missing or ineligible records are skipped. If no phrases are queued, the preview finishes directly; Repeat starts a new preview.
- Updated the learning-round product decision and project workflow overview. Project purpose and major boundaries are unchanged.


## 2026-10-17 — Compact copy controls and dictionary spacing

- All copy buttons now show only an icon, with a temporary checkmark after copying, while retaining descriptive accessibility labels and the copy announcement.
- Moved Copy original beside Play phrase on the source row and removed the speed control from dictionary detail.
- Grouped contextual word explanations and overall translation into one compact Form row so the divider no longer creates an empty full-height row; trimmed display-only surrounding whitespace.
- Updated the dictionary-detail product decision; project purpose, workflows and major boundaries are unchanged, so PROJECT.md requires no further update.


## 2026-10-17 — Complete dictionary metadata backups

- Dictionary JSON v2 now includes contextual breakdown and phrase translation, notes and preferred meaning, legacy word-help/cached definitions, timestamps, translation origin/status, and exact source/track/cue/audio links. Export always includes source context in the UI and checks its own output against importer validation.
- Added Restore backup with a preview of matching records to restore. It restores saved progress and details even when the translation is unchanged, keeps unrelated records and conflicting identities, and rolls back a failed save. Merge and translations-only modes retain their conservative update behavior. Interrupted translations are requeued safely.
- Preserved v1 import compatibility and added ISO 8601 fractional-second support. Added limits and validation for extended data and audio ranges, including overflow-safe UTF-16 context selection validation.
- Audio/media files are not embedded; restored links require the original local book identity and files. Reimporting a book with a new ID does not automatically reconnect audio. Old backups cannot recover fields that were never exported. Added docs/DICTIONARY_BACKUP.md and updated DECISIONS.md and PROJECT.md; project purpose and media-storage boundaries are unchanged.


## 2026-10-17 — Simplified dictionary detail

- Reordered dictionary detail to source phrase with inline playback, Russian translation, then Meaning in context. Source context, progress and other details follow.
- Removed the legacy Word-by-word help UI and contextual-result copy buttons. Existing saved word-help data remains intact.
- Updated DECISIONS.md and PROJECT.md for the simplified detail workflow; project purpose and major boundaries are unchanged.


## 2026-10-17 — Dictionary learning statistics

- Added live dictionary counts for all four learning levels, including zero counts. Level-4 entries now appear only in a separate Learnt phrases section at the end of the list.
- Both sections retain entry details and swipe-to-delete; deletion uses the corresponding section to avoid removing a different entry. Counts include every saved entry, regardless of translation status.
- No architectural/product decision or project overview changed; DECISIONS.md and PROJECT.md require no updates.


## 2026-10-17 — Phrase audio boundaries

- Removed the extra 0.75-second tail from phrase capture in both readers. Play phrase now uses only the selected subtitle cues.
- Existing saved phrases also drop recognizable legacy padding when the local transcript and selection match; ambiguous or custom ranges remain unchanged. Timing remains limited to subtitle cue precision, without estimating word timings.
- No architectural/product decision or project overview changed; DECISIONS.md and PROJECT.md require no updates.


## 2026-10-17 — Training start button layout

- Made Start round a full-width, large button without the surrounding Form row background or inset, and moved the empty-state hint to the section footer.
- No architectural/product decision or project overview changed; DECISIONS.md and PROJECT.md require no updates.


## 2026-10-17 — Contextual translations in training

- After Check, training cards show saved contextual word explanations and a separate overall phrase translation. Use this as translation replaces the saved phrase translation only on explicit selection.
- Missing analysis can be generated using the existing contextual translation service, with progress, errors and cancellation when leaving a card. Entries without source context use the phrase itself without inventing surrounding text.
- This extends the existing training workflow; no architectural decision, project purpose or major boundary changed. DECISIONS.md and PROJECT.md require no further changes.

## 2026-10-16 — Smoother transcript following

- Keep the active cue stationary inside a 35–60% reading zone; smoothly move its first visual line to 40% when it leaves that zone. Respect Reduce Motion and stop following on manual scrolling or selection.
- Recalculate after text layout and content geometry changes, and explicitly resume after playback and seek actions in both readers.
- Added reading-zone, layout-change, repeated-layout, selection and explicit-resume regression coverage.
- Updated the follow behavior decision. Project purpose, supported workflows and major boundaries are unchanged.

## 2026-10-16 — EPUB preparation for audiobook subtitles

- Added a local EPUB extraction step that follows spine order, preserves inline text and punctuation, removes semantic notes/navigation, and writes UTF-8 sections plus a source/skip index. The explicit Wolne Lektury profile also removes fundraising, annotation and publishing pages.
- Prepared the supplied 39-part Lalka book from EPUB: 34,399 cues per format over 32 hours, validated with the app parser/manifest validator and retained as local review-required artifacts. Added a conversion report documenting source mapping, fixes and remaining timing limitations.
- Documented chapter-to-audio matching and the existing per-track alignment/package workflow. EPUB extraction does not infer audio boundaries or change the iOS import formats.
- Shortened guided alignment targets from 60 to 20 seconds after longer windows produced local timing drift in the Lalka recordings. Bumped the alignment core version so cached output from the previous behavior is not silently reused.
- Added extraction and guided-window regression tests and updated the architecture and project overview for EPUB as a supported local preparation source. Project purpose is unchanged.

## 2026-10-15 — Background audio, contextual dictionary capture and track controls

- Enabled the iOS background audio mode alongside the existing spoken-audio playback session so audio can continue when the screen locks. Physical-device lock-screen playback and automatic track transitions still require a device smoke test.
- Changed the book slider, elapsed/total time and 10-second seeks to use the current track. Legacy virtual-part timers now also show part-relative time.
- Added Add to Dictionary to the contextual translation popup. Both reader capture actions use the same contextual result; direct capture obtains it before saving, and reopening the same last selection reuses its successful result. Saved entries contain the phrase, primary translation, word breakdown, context and exact audio source. Duplicate taps and dismissed requests cannot insert extra entries.
- Versioned the production prompt and strict response schema to return source word, lemma and concise comma-separated meanings, with blank lines between words and the overall contextual phrase translation below. Removed requests for grammatical commentary. Existing custom prompts remain, with the concise output contract enforced after them.
- Contextual word breakdowns now omit common conjunctions, prepositions and connecting words (including Polish ale, i, z, przed/pred and na), using a language-specific list with case/punctuation normalization. Short content words stay visible; function-word-only selections still translate and save normally. The v4 request carries the exact filtered word list while the overall translation retains the full phrase. This refines the existing workflow; project purpose and major boundaries are unchanged.
- Added model-error alerts with OK, bounded persistent diagnostic metadata and Export logs in Settings, the selection popup and dictionary details. Logs exclude credentials, prompt/input text and response bodies. Failed dictionary context saves restore the previous result and surface an error.
- Added distinct orange, blue, purple and green progress badges while retaining level numbers and names.
- Updated DECISIONS.md and PROJECT.md for the new capture workflow, diagnostic export and background playback. Project purpose is unchanged.

## 2026-09-24 — Direct OpenAI contextual translation with user key

- Replaced both contextual Apple Translation routes with one bounded application-wide service that
  calls the OpenAI Responses API and requires strict structured output for the selected phrase and
  its contextual explanation. Word-by-word and ordinary automatic translation remain on Apple
  Translation.
- Added an explicit cloud opt-in, model selection, and user-provided OpenAI API key management. The
  key is stored only in the device Keychain and is sent directly to OpenAI; it is not bundled with
  the app, written to `UserDefaults`, or added to the repository. Usage is billed to its owner.
- Preserved ephemeral reader previews and separately persisted dictionary results, stale-response
  guards, the last successful result on failure, and explicit acceptance before replacing a saved
  translation. Added request/error/decoding tests and documented the BYOK boundary.
- Context explanation now returns and validates one concise contextual grammar/meaning line for
  every selected word, preserves source order and duplicates, and shows the natural translation of
  the complete phrase after the word breakdown.
- Added a prompt editor backed by an optional `UserDefaults` override, with the production default
  kept in code and an explicit reset action. The application still appends its non-editable strict
  output and untrusted-context safety contract to every request.
- Recorded the direct-BYOK cloud architecture in `DECISIONS.md` and updated `PROJECT.md` because
  contextual translation is no longer local-only. No relay or project-owned API credential is part
  of this release.

## 2026-09-23 — Multi-track audiobook import and playback

- Added previewed local ZIP and strict `.book.zip` import for 1–100 audio tracks, generated stable track identities, sequential playback, cross-track global seeking, per-track resume positions, and full-book untimed reading.
- Added manifest-linked per-track SRT/WebVTT reading and dictionary audio references keyed by `(item ID, track ID)` so equal local cue times on different tracks resolve to the correct file. Plain full-text selections remain deliberately untimed.
- Added streamed archive limits and CRC/path/collision checks, staging journals, save rollback, startup recovery, and reversible library deletion so filesystem changes do not masquerade as database transactions.
- Extended the shared selection preview, phrase-audio resolver, playback intent/rate controller, transcript follow behavior, dictionary detail, and learning round UI with track-aware behavior while preserving their existing lifecycle and accessibility contracts.
- Added the strict v1 book JSON schema and a sequential multi-track alignment CLI with full preflight, reports, fail-closed publishing, and fingerprint-checked single-track reruns.
- Recorded the track-local timeline, immutable identity, untimed TXT, legacy adapter, migration, import transaction, and batch publishing decisions. Updated the project overview because multi-track ZIP import and batch alignment are now supported workflows.

## 2026-09-23 — Generated Xcode project troubleshooting

- Documented the stale local Xcode project that omitted `SelectionTranslationPreview.swift`, and its repair through `bash scripts/bootstrap.sh`.
- Added a [prevention and recovery guide](../docs/PREVENTING_GENERATED_PROJECT_DRIFT.md), linked from the README, covering regeneration triggers, build/test commands, CI generation, and safe handling of merge conflicts and concurrent edits.
- The local unsigned Debug simulator build succeeded after regeneration; no Swift source change was required. This guide documents the existing XcodeGen workflow, with no new automated enforcement. Architectural/product decisions and the project overview in `DECISIONS.md` and `PROJECT.md` are unchanged.

## 2026-09-22 — Learning and playback UX

- Changed Translate in Context in the reader to an ephemeral preview that translates the phrase and its containing sentence without creating or modifying a dictionary entry.
- Added reliable selection-triggered pause, TextKit-based transcript centering, explicit Follow recovery, and session-local 0.5×–2× playback speed controls.
- Added 5, 10, 20 and all-available learning rounds with a fixed unique starting set, retry-at-end behavior for wrong answers, save-before-advance progress, duplicate-event protection, and explicit skipped-entry accounting.
- Added phrase audio and exact-copy controls across preview, dictionary detail and learning, while keeping original/audio/context hidden until a learning answer is checked.
- Round completion now lists all valid level-4 Russian phrases from current stored data, including phrases learned before the round.
- Updated `PROJECT.md` for the expanded supported learning workflow. Project purpose and system boundaries are unchanged; no persistent preference, transfer-schema, backend or multi-track decision was introduced.

## 2026-09-22 — Cloud alignment backend implementation

- Added an undeployed AWS backend implementation for one audio + matching TXT alignment job: a
  capability-authorized HTTP API, version-pinned multipart uploads, DynamoDB state/idempotency and
  atomic global admission counters, a versioned Standard Step Functions workflow, one CPU Fargate
  worker per accepted start, manifest-gated publication, cancellation, reconciliation and cleanup.
- Preserved public testing without sign-in and the 60-minute hard duration ceiling. Job IDs do not
  grant access; each create request uses a fresh 32-byte client capability, and the service stores
  only its SHA-256 digest. Existing local import and local alignment behavior is unchanged.
- Added an OpenAPI contract, hash-locked Linux/x86_64 CPU worker dependencies, immutable image/model
  build inputs, CDK infrastructure assertions, backend race/validation tests and CI coverage.
- Recorded the benchmark and deployment gate in `docs/ALIGNMENT_BENCHMARKS.md`. No AWS resources were
  deployed, no production pricing or 60-minute benchmark is claimed, and the iOS remote upload/UI
  client remains future implementation work.
- Recorded the temporary-cloud-processing architecture in `DECISIONS.md` and updated `PROJECT.md`
  because the repository now contains an optional backend boundary even though the shipped app
  remains local-first and has no configured service endpoint.

## 2026-09-22 — Reviewed implementation proposals

- Reviewed the AWS alignment, learning UX and multi-track audiobook plans against the current code, resolved contradictory requirements, and added explicit state, timing, persistence, migration and acceptance contracts for implementation.
- Recorded the user-confirmed cloud testing scope: public job creation without sign-in, private per-job access, and recordings up to 60 minutes. Production authentication and broader hardening are deferred to the general [future improvements backlog](../docs/FUTURE_IMPROVEMENTS.md).
- These are implementation proposals, not shipped capabilities. Current architectural decisions and the project overview in `DECISIONS.md` and `PROJECT.md` are unchanged; future implementation PRs must update them when behavior changes.

Entries are ordered oldest to newest and summarize the project history recovered from the repository and Codex task history.

- Fixed Force Translation in the dictionary entry screen so it runs immediately in that screen, shows a translating state instead of “queued,” and explains that the operation may take a moment. No architectural or project-overview decision changed.

## 2026-09-15 — Native iOS foundation

- Created the SwiftUI iPhone/iPad app, XcodeGen specification, unit/UI test targets, simulator CI, and signed publishing workflows.
- Added initial setup, release, signing, and troubleshooting documentation.

## 2026-09-15 — Media transcript library

- Added local audio/video import, SwiftData library models, resume positions, transcript parsing, synchronized playback, native text selection, and phrase dictionary capture.
- Added tests for parsing, timing boundaries, Unicode ranges, backward seeking, overlap policy, dictionary persistence, and core UI flows.

## 2026-09-15 — Subtitle alignment utility

- Added the standalone TXT + audio aligner with SRT/WebVTT export, chapter offsets, guided alignment, validation diagnostics, and review output for untimed words.
- Documented the Polish sample conversion experiments and limitations.

## 2026-09-16 — Virtual learning parts and dictionary roadmap

- Added the virtual learning-parts direction so practice content can be organized without duplicating media.
- Documented translation options, Russian as the initial target, portable dictionary JSON, translation-only imports, conflict handling, and learning-session design.

## 2026-09-16 — Transcript seek synchronization

- Added seek-generation guarding so stale AVPlayer callbacks cannot overwrite a newer requested position.
- Resynchronized the displayed position after the active seek completes; the full local suite passed with 7 unit tests and 2 UI tests in the recorded task.

## 2026-09-16 — Knowledgebase governance

- Added this knowledgebase and `AGENTS.md` rule requiring every completed PR to update project knowledge.

## 2026-09-16 — Translation queue reliability

- Invalidated same-language Apple Translation configurations between dictionary jobs so every queued phrase starts instead of only the first phrase translating.
- Added a Force Translation action to dictionary entry details, with confirmation before replacing an existing translation.
- No architectural/product decision or project-overview change was required.

## 2026-09-16 — Dictionary context visibility

- Added saved source context to dictionary entry details and to the revealed side of learning cards.
- No architectural/product decision or project-overview change was required.

## 2026-09-16 — Contextual translation and sentence help

- Added a Translate in Context transcript action that compares the selected expression with a translation of its containing sentence and highlights the saved selection.
- Added on-demand word-by-word sentence help, with common grammar words hidden by default but available through a reveal toggle.
- Added editable preferred-meaning and personal-note fields, while preserving existing manual or imported translations until the learner explicitly accepts a contextual candidate.
- Translation configurations prefer Apple's high-fidelity strategy on iOS 26.4 and later while retaining the iOS 18-compatible path on earlier systems.
- Moved CI and publishing to the macOS 26 runner with Xcode 26.6 so the iOS 26 Translation APIs compile and are tested consistently.
- Recorded the contextual translation architecture and updated the supported dictionary workflow; no broader project-purpose or boundary change was required.

## 2026-09-16 — Sentence-based source context

- Limited captured dictionary context to the selected sentence plus the preceding and following sentences.
- Trimmed the adjacent sentences to 15 words each, preserving the selected phrase and reducing oversized context cards.
- No architectural/product decision or project-overview change was required.

## 2026-09-17 — Polish Wiktionary definitions

- Added explicit per-word Polish Wiktionary lookup to word-by-word help, with numbered Polish definitions, usage labels, matching examples, source attribution, retry, and refresh states.
- Cached successful Wiktionary results inside saved word-help data so previously viewed definitions remain available offline and survive translation refreshes.
- Added fixture-backed coverage for multilingual article isolation, definition/example parsing, errors, and Polish query encoding.
- Recorded Wiktionary as the first third-party runtime data source and updated the project boundary accordingly; the app still has no backend or analytics.

## 2026-09-17 — Listening and vocabulary market research

- Added [market research](../docs/LANGUAGE_LEARNING_MARKET_RESEARCH.md) comparing LingQ with nine alternatives/workflows, linking user feedback, and prioritizing listening and vocabulary-retention features.
- Mapped proposed features to the current Swift implementation with estimated engineering effort, illustrative budgets, operating-cost assumptions, and a phased validation plan.
- Recommendations are not adopted product or architectural decisions. No project-overview or supported-workflow change was made.
- Перевёл отчёт исследования на русский язык, сохранив структуру, источники, оценки и технические рекомендации.

## 2026-09-17 — Audio playback for saved phrases

- Saved dictionary entries now retain the absolute transcript cue start/end when created from timed media.
- Added a Play/Pause control to dictionary-entry details that reuses the local source media and plays only the saved phrase range.
- Entries imported from JSON, created from untimed text, or whose source media is unavailable continue to work without audio and show an unavailable state.
- Added coverage for source-index preservation and persisted audio ranges. No new architectural decision or project-overview change was required.
- Extended phrase audio to include every subtitle cue touched by a selection and a bounded 0.75-second tail, preventing natural speech from being cut at the first cue boundary.
- Increased the document-picker UI test wait for slower CI simulator launches; no product or architectural decision changed.

## 2026-09-17 — Offline Polish form resolution

- Added a bundled SGJP morphology index containing 4,934,967 Polish surface forms and 5,252,824 unique form-to-lemma pairs.
- Polish Wiktionary lookup now resolves missing inflected forms locally, including `został → zostać`, before requesting the lemma article.
- Added an explicit lemma chooser for ambiguous forms, first-use database installation, SGJP attribution, and a reproducible pack builder.
- Recorded the bundled language-pack architecture and updated the supported dictionary workflow and repository map.

## 2026-09-18 — Reading and review refinements

- Fixed transcript content and highlight synchronization when switching between virtual audiobook parts.
- Expanded partial transcript selections to complete word boundaries before saving or translating them, while preserving the exact selected range in context.
- Added compact phrase translations to dictionary rows.
- Learning cards now highlight the saved phrase in source context and allow the Russian translation to be edited directly.
- Wrong learning answers now return to the end of the current queue, and the round continues until every queued entry is answered correctly.
- Polish Definition failures are now written to the iOS unified log and to a bounded, protected local diagnostic file; the existing dictionary export includes that log and environment metadata for support.
- Recorded the local diagnostic-retention/export decision; no project-overview change was required.
