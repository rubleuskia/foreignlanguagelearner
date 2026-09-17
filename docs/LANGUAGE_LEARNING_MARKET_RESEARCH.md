# Language-learning market research: listening and vocabulary retention

Research date: **17 September 2026**. Prepared for the Foreign Language Learner iOS project.

## Recommendation

Build a short, connected practice loop: **listen to something interesting → save a phrase and its original audio → recall its meaning from audio → revisit it on a spaced schedule → recognize it in another sentence**.

The strongest opportunity for this project is the combination of LingQ's personal-content approach, Migaku's effortless audio-card capture, Language Reactor's playback controls, and Anki-style scheduling. A useful first release does not require cloud AI or a licensed video catalogue.

Prioritize three additions: sentence replay controls, audio-first vocabulary cards, and scheduled reviews. Estimated implementation: **14–23 developer-days**, or **17–28 days with 20% contingency**, approximately **4–6 working weeks for one experienced iOS developer**. At an illustrative $600/day, the contingency-inclusive budget is **$10,200–$16,800**. This is an engineering planning estimate, not a supplier quote or measured market rate.

## Scope and evidence quality

This is qualitative desk research, not a market-share study or controlled comparison of learning outcomes. It covers LingQ and nine relevant alternatives/workflows. Selection favors listening, authentic content, vocabulary capture, and retention; broad beginner curricula and conversation marketplaces are outside the detailed comparison.

Official product pages establish advertised capabilities. Reddit, product forums, and individual Trustpilot reviews provide user sentiment. The linked feedback sample includes recent 2025–2026 discussions and older, explicitly dated examples where the workflow remains relevant. Older complaints do not establish current bugs. Vendor-selected testimonials are labeled separately and carry less weight. Search results from competitors' promotional comparison articles were not used as independent evidence.

“Most liked” below means repeatedly praised in this purposive sample, not a statistically ranked popularity survey. “Strong” evidence means convergence across several discussions/products; “moderate” means fewer or older observations. Neither is a claim of experimentally demonstrated retention gains. The reports are self-selected, English-language, and disproportionately represent engaged learners of Japanese and major European languages; validation with Polish learners is still needed. No paid subscriptions were purchased and no hands-on competitor benchmark was conducted.

## Competitive landscape

| Tool | Relevant product behavior | User feedback and limitations | Lesson for this project |
|---|---|---|---|
| **LingQ — reference product** | Imported content, synchronized reading/listening, saved vocabulary and progress tracking. [Official overview](https://www.lingq.com/en/) | Learners praise importing material they actually enjoy. A January 2025 forum request asks for automatic sentence repetition and pauses to reduce manual intervention. [December 2025 user discussion](https://www.reddit.com/r/languagelearning/comments/1pwa652/your_comments_please_on_using_lingq/), [playback request](https://forum.lingq.com/t/more-controls-for-audio-playback/973535) | Keep personal content central; make repeated listening easier than managing a vocabulary database. |
| **Migaku** | Creates cards containing a word, context, original audio and optional screenshot; integrated review. [Official product](https://migaku.com/) | February 2025 users value the convenience of immediate sentence/audio cards and mobile capture; others prefer free tools or criticize price and setup. January 2026 feedback again praises audio extraction after initial setup. [2025 discussion](https://www.reddit.com/r/LearnJapanese/comments/1imwsgn/is_migaku_worth_the_money/), [2026 discussion](https://www.reddit.com/r/languagelearning/comments/1q9x5jb/worth_use_migaku/) | Strongest benchmark for turning an encountered word into a useful review card with minimal work. |
| **Language Reactor** | Subtitle-assisted viewing, lookup and sentence-level playback; its indexed official guide documents automatic pausing. [Product](https://www.languagereactor.com/), [official guide](https://dev.languagereactor.com/help/basic) | Users explicitly recommend auto-pause, repeat and quick lookup. These testimonials establish the appeal of the workflow, not current reliability across streaming sites. [April 2023 discussion](https://www.reddit.com/r/languagelearning/comments/12w9frn), [June 2022 discussion](https://www.reddit.com/r/languagelearning/comments/vlec04) | Reproduce the controls for existing local media. A browser extension is a separate, larger undertaking. |
| **Readlang** | Click/drag to translate words and phrases, automatically save them for flashcards, and request contextual explanations. [Official product](https://readlang.com/) | A March 2025 user praises easy capture/review with little setup, but finds video import awkward. A May 2026 forum user wants less frequent, more configurable reviews. [Workflow feedback](https://www.reddit.com/r/languagelearning/comments/1jfv46i), [scheduling feedback](https://forum.readlang.com/t/customized-spaced-repetition/5085) | Keep capture lightweight and scheduling adjustable. Reading simplicity is useful even in an audio-centered app. |
| **Lingopie** | Entertainment-led learning with interactive subtitles and vocabulary practice. [Official product](https://lingopie.com/) | Vendor-selected reviews praise click-to-save flashcards and subtitle translation. An August 2026 Reddit reviewer reports insufficient personally interesting content and dissatisfaction with renewal/refund handling; this is one account, not an adjudicated finding. [Selected testimonials](https://lingopie.com/reviews), [independent complaint](https://www.reddit.com/r/languagelearning/comments/1vehalb/lingopie_review_do_not_recommend/) | Interesting content drives use, but catalogue size alone does not guarantee relevance. Clear subscriptions matter if monetized. |
| **FluentU** | Curated videos, interactive captions, detailed explanations and quizzes with examples from other videos; also advertises Netflix/YouTube support. [Official product](https://www.fluentu.com/) | Trustpilot users praise contextual quizzes with varied speech, personal vocabulary lists, and daily targets. These are individual reviews; the aggregate rating mixes product and support experiences. [Feedback, including August 2024 and June 2025 reviews](https://www.trustpilot.com/review/fluentu.com) | Show a saved word in more than one authentic sentence, and make daily practice easy to start. |
| **Yabla** | Authentic video with caption loop, slower playback, and Scribe dictation. [Official player tutorial](https://english.yabla.com/player_cdn.php?id=14619&tlang_id=en), [dictation explanation](https://www.yabla.com/yabla-blog/the-language-learning-game-for-dictation-introducing-scribe/) | Older user discussion praises Scribe for ear training, alongside criticism of other exercises. Treat this as a durable feature signal with limited recency. [March 2021 discussion](https://www.reddit.com/r/languagelearning/comments/m1mfwa) | Add short “type what you hear” exercises after basic audio review works. |
| **Clozemaster** | Sentence gap-filling, spaced review, listening practice and offline collections; Polish appears in its listening-language list. [Product](https://www.clozemaster.com/), [Pro features and language availability](https://www.clozemaster.com/pro) | Users praise vocabulary in sentences and listening-first rounds. A long-running review likes hands-free Radio mode; a reply questions whether simply hearing the missing word tests meaning. [September 2023 feedback](https://www.reddit.com/r/Spanish/comments/16mx76k), [2021 review with later updates/comments](https://www.reddit.com/r/clozemaster/comments/mhz7vo/my_1_year_general_review_of_clozemaster_just_my/) | Separate sound recognition, meaning recall and spelling; they should not all produce the same “learned” score. |
| **Satori Reader** | Japanese-specific stories with audio, contextual language explanations and review support. [Official product](https://www.satorireader.com/) | July 2022 users value sentence-context review with audio and the supported transition toward independent reading. The product's current site emphasizes human-authored content. [User discussion](https://www.reddit.com/r/LearnJapanese/comments/w015h0/satori_reader/) | A model for quality and contextual help, rather than a direct Polish-language substitute. Human editorial quality is an ongoing cost. |
| **Anki + asbplayer + Yomitan workflow** | Modular alternative: multimedia flashcards and scheduling in Anki; subtitle/audio capture through asbplayer; dictionary lookup through Yomitan. [Anki](https://apps.ankiweb.net/), [asbplayer documentation](https://github.com/asbplayer/asbplayer), [Anki scheduling manual](https://docs.ankiweb.net/deck-options) | Migaku comparison users describe obtaining similar results with this stack, but disagree on setup difficulty. One technically experienced user reports several hours of setup. [User comparison](https://www.reddit.com/r/LearnJapanese/comments/1imwsgn/is_migaku_worth_the_money/) | Powerful substitute and export destination. The opportunity is a simpler integrated iPhone workflow. |

### Price and positioning signals

These are observed public web prices, not normalized checkout quotes. Currency, tax, region, billing period and app-store pricing can differ.

| Product | Observed price | Implication |
|---|---|---|
| Readlang Premium | $6/month or $48/year; Premium Plus $15/month or $120/year. [Pricing](https://readlang.com/pricing) | Establishes a relatively inexpensive benchmark for personal-content vocabulary tools. |
| Satori Reader Pro | $9/month or $89/year. [Pricing](https://www.satorireader.com/pricing) | A specialist curated product competes through depth and content quality. |
| LingQ Premium | Retrieved page served GBP: £12.99 monthly or £103.99 annually. [Pricing](https://www.lingq.com/en/signup/) | Broader content and import workflow occupies a higher subscription tier than a basic reader. |
| Migaku / Clozemaster | Pricing pages were reachable, but exact amounts were not exposed in retrieved page text. [Migaku plans](https://migaku.com/pricing), [Clozemaster Pro](https://www.clozemaster.com/pro) | No unverified dollar comparison is used. |

Product-positioning inference: the potential niche is **personal listening material, easy capture, dependable offline review, and explicit listening progress**. That is a hypothesis to validate, not evidence of an unserved market. The paid-vs-free discussions suggest some users pay for saved setup time, while others strongly prefer composable tools.

## Most valued features, ranked for this project's goal

The order combines observed enthusiasm, relevance to listening/retention, and feasibility; it is not a vote count.

| Rank | Feature and user experience | Evidence strength and examples | Proposed behavior |
|---|---|---|---|
| 1 | **Save vocabulary with its original sentence and voice.** Preserve the moment that made the word meaningful. | **Strong:** Migaku convenience/audio feedback, Satori audio-context reviews, FluentU contextual examples. [Migaku](https://www.reddit.com/r/languagelearning/comments/1q9x5jb/worth_use_migaku/), [Satori](https://www.reddit.com/r/LearnJapanese/comments/w015h0/satori_reader/), [FluentU](https://www.trustpilot.com/review/fluentu.com) | Select a phrase once; save context and a replayable cue range. Let the learner adjust clipping boundaries. |
| 2 | **Replay, slow down, and pause after a sentence.** Understand difficult speech without repeatedly dragging a timeline. | **Strong:** independent Language Reactor recommendations plus LingQ playback requests. [Playback feedback](https://www.reddit.com/r/languagelearning/comments/12w9frn), [LingQ request](https://forum.lingq.com/t/more-controls-for-audio-playback/973535) | Previous/current/next cue, repeat count, speed selection and optional pause between repetitions. |
| 3 | **Quick lookup and card creation in the same screen.** Avoid typing definitions or switching tools. | **Strong:** Readlang workflow praise and Migaku discussions. [Readlang](https://www.reddit.com/r/languagelearning/comments/1jfv46i), [Migaku](https://www.reddit.com/r/LearnJapanese/comments/1imwsgn/is_migaku_worth_the_money/) | Small contextual sheet, editable meaning, save confirmation that does not require dismissing an alert. |
| 4 | **Review at useful intervals, with a manageable daily queue.** Remember saved words without endlessly rereading easy cards. | **Moderate:** praise for integrated review, but disagreement about review frequency and workload. [Satori](https://www.reddit.com/r/LearnJapanese/comments/w015h0/satori_reader/), [Readlang scheduling request](https://forum.readlang.com/t/customized-spaced-repetition/5085) | Due-first reviews, new-card limit, undo, suspend and continued review of previously learned cards. |
| 5 | **Listen before seeing text.** Distinguish knowing a printed word from recognizing it in speech. | **Moderate:** Clozemaster listening-mode praise, including later comments; not a controlled effectiveness comparison. [Listening review](https://www.reddit.com/r/clozemaster/comments/mhz7vo/my_1_year_general_review_of_clozemaster_just_my/) | Play audio with transcript hidden; reveal meaning and text only after an attempted answer. |
| 6 | **Use personally interesting, suitably difficult content.** Practice feels like reading/watching something worth finishing. | **Strong:** LingQ import praise; Readlang personal-content workflow; Lingopie catalogue complaint provides the counterexample. [LingQ](https://www.reddit.com/r/languagelearning/comments/1pwa652/your_comments_please_on_using_lingq/), [Readlang](https://www.reddit.com/r/languagelearning/comments/1jfv46i), [Lingopie](https://www.reddit.com/r/languagelearning/comments/1vehalb/lingopie_review_do_not_recommend/) | Improve existing imports and offer a small starter pack before building a large library. |
| 7 | **Explain the meaning in this sentence, including phrases.** Resolve ambiguity beyond a one-word translation. | **Moderate:** Readlang users call explanations valuable but request better context handling. [Context feedback](https://forum.readlang.com/t/feature-improvement-not-quite-so-context-aware-explain/2249) | Keep sentence translation, dictionary senses and personal notes close together; make correction easy. |
| 8 | **Dictation and gap-filling from real speech.** Catch words that disappear in connected speech. | **Moderate/older:** Yabla Scribe discussion and Clozemaster context praise. [Yabla](https://www.reddit.com/r/languagelearning/comments/m1mfwa), [Clozemaster](https://www.reddit.com/r/Spanish/comments/16mx76k) | Begin with one saved phrase or short cue; show accent/spelling feedback separately from meaning recall. |
| 9 | **Hands-free listening and review playlists.** Reuse material while walking or commuting. | **Moderate:** explicit praise of Clozemaster Radio; broader demand for smoother audio control. [Radio feedback](https://www.reddit.com/r/languagelearning/comments/zs4ghf), [LingQ](https://forum.lingq.com/t/more-controls-for-audio-playback/973535) | Background audio, lock-screen controls, and phrase → pause → answer playback. Passive listening does not count as successful recall. |
| 10 | **Visible progress and freedom to move data.** Know what improved and avoid recreating years of vocabulary. | **Moderate:** known-word tracking praise, export/ownership preferences, and daily-target feedback. [Migaku](https://www.reddit.com/r/LearnJapanese/comments/1imwsgn/is_migaku_worth_the_money/), [ownership discussion](https://www.reddit.com/r/languagelearning/comments/1j5kylp), [FluentU](https://www.trustpilot.com/review/fluentu.com) | Track listening recall separately from saved-word totals; retain JSON and add practical Anki export. |

The major tension is between intensive study and enjoyment. Repeating every sentence and saving every unknown word may interrupt the content too much. Offer an ordinary listening mode and an explicit practice mode, and allow a small number of selected words to enter review each day. This is a product-design inference from the combined feedback.

## What the project already has

Repository inspection, rather than README claims alone, is the basis for the estimates:

| Area | Implemented foundation | Gap relevant to this research |
|---|---|---|
| Platform | Swift 6, SwiftUI, SwiftData, iPhone/iPad; `project.yml` targets **iOS 18**. | `knowledgebase/PROJECT.md` still says iOS 17+, so the build configuration is used here. |
| Media | Local audio/video, SRT/WebVTT cues, untimed TXT, saved playback position and virtual learning parts. | Automatic transcription/alignment is not in the app. The separate Python alignment utility is not an iOS component. |
| Player | `PlaybackController` uses AVPlayer, bounded playback and generation-protected seeks; reader has ±10-second controls. | No dedicated sentence loop/rate UI; player ownership is inside `ReaderView` and closes when it disappears. No established background/lock-screen workflow. |
| Vocabulary | `DictionaryEntry` stores text, context, selection offsets, source identity, optional segment index, translation and notes. | No durable audio-range snapshot or independent listening-review state. |
| Practice | `LearningSessionView` picks up to ten random eligible entries; translation first, reveal original/context, self-mark right/wrong. | No due dates, review log or audio question. Entries at level 4 stop being eligible; eligibility also requires Russian target translation. |
| Language help | Apple Translation, explicit contextual translation, Polish Wiktionary lookup and cached definitions. | Translating the selection and surrounding sentence separately is not the same as contextual sense disambiguation. |
| Portability | JSON schema v1 preserves dictionary content and progress. | It does not package original audio or SRS history; imported entries lack a usable local media association by default. |

Relevant implementation: [models](../App/Models/LibraryModels.swift), [learning view](../App/Views/LearningSessionView.swift), [reader](../App/Views/ReaderView.swift), [playback](../App/Services/PlaybackController.swift), [dictionary transfer](../App/Services/DictionaryTransferService.swift), [build configuration](../project.yml).

**Important integration trap:** the reader filters transcript segments for each virtual part, then saves the selection's segment index. An index from that filtered document is not necessarily an index into the full item's transcript. Audio cards must capture validated absolute timestamps/stable cue identity at selection time, rather than assume `item.segments[entry.segmentIndex]` points to the correct audio. Cross-cue phrases also need both range endpoints. Existing entries require best-effort recovery or manual relinking.

## Feature integration cost

Assumptions: one experienced Swift/iOS developer familiar with the repository; 8-hour developer-days; UI implementation, ordinary model migration and focused tests included. Estimates are incremental additions to this codebase, not prices for integrating proprietary competitor SDKs. Dollar examples use **$600/day solely as a replaceable budgeting assumption**; multiply days by your own rate. Rows dependent on other features exclude that prerequisite's cost.

“$0 usage fee” means the proposed local design adds no per-call hosting/API charges. It still costs developer maintenance, device storage/battery, and normal app distribution overhead.

| Priority / feature | Short technical scope | Effort / illustrative labor | Recurring cost and principal uncertainty |
|---|---|---|---|
| **P0 — Sentence playback** | Add cue navigation, bounded looping, persisted playback rate, pause/repeat settings; retain seek-generation guards. Handle gaps, overlaps and part boundaries. | **3–5 days / $1,800–$3,000** | $0 usage fee. Caption boundaries can split spoken phrases; allow range adjustment. |
| **P0 — Audio-first cards and capture** | Store media identity + absolute start/end + text snapshot; replay original audio before revealing context/meaning. Add explicit unavailable-audio state and reduce capture friction. | **5–8 days / $3,000–$4,800** | $0 usage fee with referenced local media. Missing sources, cross-cue selection and old-entry repair drive effort. Depends on playback work. |
| **P0 — Spaced review and daily queue** | Add per-card scheduling state, append-only review events, due queue, daily new-card limit, undo/suspend and migration. Keep learned items eligible for maintenance reviews. | **6–10 days / $3,600–$6,000** | $0 usage fee. Evaluate a pinned Swift FSRS package; include adapter and scheduler fixture tests. Depends on final card modes. |
| **P1 — Background audio and review playlist** | Move playback ownership above reader; configure background audio, interruptions, route changes, now-playing metadata and remote commands. Add audio/pause/answer queue. | **4–7 days / $2,400–$4,200** | $0 usage fee. Requires real-device lock-screen, Bluetooth and video-background testing. Depends on audio cards. |
| **P1 — Cloze and short dictation** | Derive gaps from saved selection offsets, accept typed answers, provide Unicode-aware comparison and hints. Keep comprehension and spelling results distinct. | **4–7 days / $2,400–$4,200** | $0 usage fee. Transcript accuracy and acceptable answer variants matter. Depends on audio-card infrastructure. |
| **P1 — Same word in other local contexts** | Build a local transcript occurrence index; surface a few alternate sentences/audio examples. Start with exact normalized forms and user-selected phrase matches. | **4–7 days / $2,400–$4,200** | $0 usage fee. Polish inflection and homographs limit exact matching; full morphology is excluded. |
| **P1 — Learning progress and gentle reminders** | Summarize ReviewEvents by listening/reading mode, show due count and listening time; optional local notification. | **2–4 days / $1,200–$2,400** | $0 usage fee. Depends on SRS logs; avoid calling saved words or passive plays “retained.” |
| **P1 — Anki export with audio** | Export UTF-8 fields and clipped audio files with an import guide; document desktop Anki as the initial import route. Keep existing JSON. | **3–5 days / $1,800–$3,000** | $0 usage fee. Depends on audio cards. Full `.apkg` generation, mobile one-tap import and two-way sync are excluded. |
| **P2 — Known-word highlighting and difficulty estimate** | Add vocabulary identity/status and transcript matching; show estimated unfamiliar-word fraction for local items. | **5–9 days / $3,000–$5,400** | $0 usage fee for basic local matching. Lemmatization and frequency data are separate language-specific work. No CEFR accuracy promised. |
| **P2 — Easier content import** | iOS share extension for supplied text/files plus a user-confirmed import queue; improve matching media/transcript selection. | **5–9 days / $3,000–$5,400** | No required server for files/text. General webpage extraction, EPUB support, streaming downloads and auto-transcription are excluded. |
| **P2 — Contextual AI explanation** | Optional service proxy, explicit opt-in, structured responses, caching, editable results, quotas and error handling. Build on existing notes/help UI. | **5–9 days / $3,000–$5,400** | Provider tokens + hosting; no provider selected or price quoted. Changes the local-only processing boundary. |
| **P2 — In-app transcription/alignment** | First test Polish recordings on supported devices; then add model availability/download handling, transcription job lifecycle, timing correction and review UI. | **2–3 day spike; 10–20 more days for a supported local MVP / $7,200–$13,800 total** | Native supported path can avoid API fees; device/locale availability is a gate. Cloud fallback or a bundled model requires re-estimation. |

The existing [Swift FSRS implementation](https://github.com/open-spaced-repetition/swift-fsrs) is MIT-licensed and advertises FSRS-6 and FSRS-5 support. Treat it as a candidate, not a dependency already approved or tested here. Pin a reviewed revision and verify parameters, scheduling fixtures and compatibility; selecting a retention target also changes review workload, as described in the [Anki manual](https://docs.ankiweb.net/deck-options).

For background playback, the implementation needs more than the audio-session category already present: player lifetime, background configuration and remote controls matter. Apple's [media playback guide](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MediaPlaybackGuide/Contents/Resources/en.lproj/RefiningTheUserExperience/RefiningTheUserExperience.html) describes now-playing/remote-command integration and video presentation considerations. For transcription, Apple explicitly exposes device and locale availability checks in [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber); do not assume the project's iOS 18 baseline or Polish content works with every newer speech API.

### Storage and optional cloud economics

Reference existing media for initial audio cards. If portable clips are later stored, **1,000 ten-second clips at 64 kbit/s require approximately 80 MB**, before metadata/container overhead: `1,000 × 10 × 64,000 ÷ 8`. Existing source recordings may occupy much more space. Exported clips should be independent of whether the source library item is present.

A local P0 release has **$0 incremental server/API usage cost**. Optional cloud costs must be evaluated against usage, not a generic “AI is cheap” assumption:

- Transcription: monthly users × uploaded minutes per user × vendor rate/minute, plus storage and transfer. For example, 100 users × 120 minutes = **12,000 billable minutes**, before retries.
- Explanations: number of uncached requests × input/output tokens × the respective provider rates. For example, 100 users × 10 requests/day × 30 days = **30,000 requests/month**.
- Hosting, monitoring, abuse controls and support are additional. These are workload examples, not current vendor price quotes.

Streaming-service integration, a licensed entertainment catalogue, cross-device cloud sync and a full beginner curriculum are **not covered by the feature budgets above**. Each introduces materially different engineering and operational work. Content partnerships require negotiated access; no assumption is made that competitors' media or definitions can be reused. For this goal, local files and user-supplied transcripts already provide a workable starting point.

## Proposed implementation sequence

### First release: complete the listening-to-memory loop

1. Implement sentence playback and reliable audio anchors.
2. Save/review audio-first cards with hidden text, editable meaning and replay.
3. Add spaced scheduling, due-first practice and a modest configurable new-card limit.

Combined P0 estimate: **14–23 days** before contingency. Add approximately 20% for integration uncertainty: **17–28 days**, rounded up, or **$10,200–$16,800 at the example day rate**. Includes local data migration, basic daily queue and focused verification; excludes cloud services, standalone audio export, background playback, content production and App Store review waiting time.

Suggested first-use flow: import a ten-minute recording with transcript; listen; save three to five useful phrases; do a short audio recall session; return when cards are due. Those numbers are starting product defaults to test, not scientifically established optimums.

### Second release: make the habit fit daily life

Add background playback/review playlists, short dictation, and progress summaries: **10–18 incremental days**, before contingency. Add Anki export or alternate-context retrieval next according to feedback, rather than committing to every P1 row at once.

### Later: reduce content preparation

Test whether users primarily abandon the app during import, during review, or because their material is too hard. Prioritize import/transcription only if preparation is the bottleneck; prioritize alternate examples and level guidance if comprehension is the bottleneck.

## Technical design notes for the first release

- **Separate vocabulary from practice cards.** One dictionary entry may produce listening-comprehension and text-production cards with different histories. A successful written answer should not silently mark listening as mastered. Keep the current learning level as a display/backward-compatibility field initially.
- **Persist durable source anchors.** Store source item identity, absolute cue range, transcript snapshot and audio provenance. Validate bounds. Cue-level audio is sufficient for v1; word-level forced alignment is unnecessary for the recommended workflow.
- **Keep review evidence.** Record card ID, mode, timestamp, rating and whether an answer/hint was revealed. Provide undo. The schedule must be deterministic under a test clock and resilient to timezone changes.
- **Migrate conservatively.** Existing level-4 entries should not become a huge immediate due backlog; enroll existing vocabulary gradually. Do not invent past review dates. Imported JSON with no local audio should keep working as text practice, with optional explicitly labeled synthetic pronunciation if a suitable installed voice is available.
- **Version portability deliberately.** Existing imports accept schema v1 only. Preserve its compatibility or introduce a versioned migration when adding review history and audio bundles; a source UUID alone cannot reconnect another device's media reliably.
- **Verify the risky paths.** Test selection in later virtual parts, cross-cue phrases, untimed TXT, overlapping cues, missing sources, old dictionary imports, undo, long review gaps, and “learned” cards becoming due again. Real-device playback tests should accompany player changes.

## How to validate that the features help

Run a small formative pilot with 5–8 learners who use imported spoken content, including Polish learners. Ask them to import an item, save three phrases, practice by ear, and return after several days. This sample can expose usability problems; it cannot establish population-level effectiveness.

Measure time and interactions from phrase selection to usable card, whether users understand the daily queue, capture errors, voluntary return to listening, and review abandonment. For retention, distinguish **meaning recalled from audio**, **word recognized in text**, and **spelling accuracy**.

Compare a small matched set of words reviewed with the current text workflow against audio-first scheduled practice after 7 and 30 days. Include a new sentence or voice where available so remembering one recording is not mistaken for general word recognition. Counterbalance assignment and report results as exploratory. Start with local logs or explicit participant reports; the application currently has no analytics backend.

The proposed roadmap remains a recommendation. This research does not adopt a new architecture, add dependencies, or change the project's supported workflow.
