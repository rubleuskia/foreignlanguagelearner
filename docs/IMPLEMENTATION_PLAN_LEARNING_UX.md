# План реализации улучшений обучения и воспроизведения

**Статус:** проверенная постановка для реализации; изменения ещё не реализованы.  
**Ревью:** 2026-09-22. Источник истины — текущие Swift-файлы и `project.yml` (iOS 18, Swift 6), а не устаревшее упоминание iOS 17 в knowledgebase.

## 1. Решения после ревью

Ниже одна обязательная трактовка. Альтернативы и противоречащие ей «значения по умолчанию» из прежнего черновика удалены.

| Вопрос | Обязательное поведение |
|---|---|
| Перевод первым | В detail сначала Russian translation, затем Original, Audio, Source context. В игре перевод — вопрос; оригинал и контекст доступны только после Check. |
| Translate in Context | Только временный value-preview, без создания `DictionaryEntry` даже в несохранённом виде. Отдельный экран и coordinator. |
| Add to Dictionary | Сохранить текущий сценарий: вставка → успешный save → enqueue → сообщение Added. Текущий код **не открывает** detail после Add; не добавлять новый переход. |
| Размер раунда | 5 / 10 / 20 / All available; фиксированное число уникальных записей на старте. Wrong повторяет запись до Right. |
| Repeat | Новый набор eligible-записей с тем же выбранным вариантом размера. Значение хранится только в открытом `LearningSessionView`; новое открытие начинает с 10. |
| Финальный список | **Все** глобально выученные записи (`learningLevel == 4`) после сохранения ответа, включая выученные до раунда. Это приоритетное решение из раздела «Принятые продуктовые решения» исходного документа. Не подменять списком Right текущего раунда. |
| Статистика | Right/Wrong — попытки этого раунда; «Completed X of N» — уникальные завершённые записи этого раунда. Завершённая в раунде запись не обязательно имеет глобальный level 4. |
| Скорость | 0.5 / 0.75 / 1 / 1.5 / 2×; новое владение контроллером начинается с 1×; внутри одного контроллера скорость переживает pause, seek, open и close. Без UserDefaults/AppStorage. |
| Цвет | Семантический `.tint` для числа completed, `.secondary` для общего числа; текст/значок обозначают завершение. Без настроек цвета. |
| Пауза при selection | Только Reader, при начале пользовательского непустого выделения. Очистка выделения и закрытие preview не возобновляют звук автоматически. |

Не включать в эту задачу AWS, multi-track, background audio, новый алгоритм перевода, переносимые настройки, изменение JSON-схемы словаря или изменение смысла уровней 1–4.

## 2. Проверенные места кода и важные ограничения

- `ReaderView.swift`: обе selection actions сейчас создают запись до `switch`; `audioRange(for:)` использует документ и `sourceIndices` текущей части.
- `TranscriptTextView.swift`: `scrollRangeToVisible` лишь показывает cue; follow меняется при drag/selection. Action получает expanded text, но **исходный** range — исправить согласованность.
- `ContextualTranslationCoordinator.swift`: `begin`, completion и error handlers пишут в ModelContext. Этот coordinator нельзя вызывать из preview. Переиспользовать чистые `ContextSentenceExtractor.sentence(text:selection:)` и `QualityTranslationConfiguration` допустимо.
- `PlaybackController.swift`: сейчас нет `pause()` и свойства выбранной скорости; `toggle()` вызывает `player.play()`, `open()` вызывает `close()`. Seek уже защищён `seekGeneration`: сохранить эту защиту.
- `DictionaryEntryDetailView.playAudio`: после паузы открывает файл заново. Для настоящего play/pause нужно сохранять позицию, а не повторять этот дефект в игре.
- `LearningSessionView`: `prefix(10)` и append при Wrong смешивают число попыток с размером раунда. `LearningQueue` находится в `LibraryModels.swift`.
- `DictionaryEntry.isLearningEligible`: Russian target, непустой перевод, ready, level < 4. Не упрощать до одного `learningLevel < 4`.
- `DictionaryTransferService` остаётся без изменения формата. Сохранённые ручные/импортированные переводы не заменять побочным contextual-запросом.

## 3. Временный перевод и согласованная selection

### 3.1 Один диапазон для одного действия

В `editMenuForTextIn` сначала проверить UTF-16 range: location не NSNotFound, length > 0, границы внутри NSString, `Range(range, in: text)` допустим. Затем вызвать `WordSelectionExpander` и заново проверить результат.

Для обеих custom actions использовать **expandedRange** одновременно для:

- исходного substring;
- пересечения с cue ranges и первого segment index;
- `Coordinator.context(in:selection:)`;
- `ReaderView.audioRange(for:)`.

Не менять нативное Copy: оно копирует фактически выделенный пользователем текст. Не нормализовать текст контекста после расчёта `SelectionContext.selection`, иначе UTF-16 offsets станут неверными. Для перевода/словаря можно отдельно нормализовать выбранную фразу существующим методом.

### 3.2 Явная value-модель

Создать `App/Models/SelectionTranslationPreview.swift`:

```swift
struct SelectionTranslationPreview: Identifiable {
    let id: UUID
    let selectedText: String
    let sourceLanguageCode: String
    let targetLanguageCode: String // "ru"
    let context: SelectionContext?
    let sourceItemID: UUID
    let sourceTitle: String
    let audioRange: ClosedRange<Double>?
}
```

Никаких `@Model`, `DictionaryEntry`, ModelContext или полей learning progress. Preview не сериализовать на диск. Reader создаёт его только в ветке `.translateInContext`; `.addToDictionary` сохраняет запись и запускает background translation только после успешного save. При ошибке save не enqueue, удалить вставленную запись и показать ошибку, как сейчас.

### 3.3 Coordinator и экран

Создать `SelectionTranslationCoordinator.swift` и `SelectionTranslationView.swift`. Coordinator — `@MainActor @Observable`, принадлежит одному preview. Он не принимает ModelContext и не обращается к общему DictionaryTranslationCoordinator.

- Вход: snapshot preview; результат: `selectedTranslation`, optional `sentenceTranslation`; состояния idle / preparing / translating / ready / failed(message).
- Чистым extractor получить предложение из `context.text` и `context.selection`. Если контекст отсутствует/невалиден, перевести только фразу и показать «Context is unavailable». Не заменять предложение всем транскриптом.
- Использовать существующий Apple Translation flow: availability, prepareTranslation при необходимости, `.translationTask(configuration)`, `QualityTranslationConfiguration.next`. Отдельные request IDs `selection` и `sentence`; сопоставлять по ID, не по порядку ответов.
- Стартовать один раз после появления preview. Повторный SwiftUI render не запускает перевод заново. Retry — явная кнопка.
- Каждый запрос получает уникальный UUID token. Перед каждой записью status/result проверить и token, и preview ID. На dismiss отменить задачу/инвалидировать token. Даже неотменяемый поздний ответ должен игнорироваться.
- Перевод фразы и отдельного предложения не обещает «перевод фразы с учётом контекста» на уровне модели: API получает два самостоятельных текста. Подписи — «Phrase translation» и «Sentence translation».
- Экран: phrase translation (или состояние), original, доступное phrase audio, source sentence, sentence translation. Copy для имеющегося текста. Без editing/progress/word help/Wiktionary и без кнопки Save to Dictionary в этом scope.
- Reader ставит звук на паузу до показа sheet. Preview использует собственный playback controller, закрывает его на dismiss; Reader после этого остаётся на паузе.

Unit/integration gate: in-memory SwiftData с существующей записью; выполнить успешный preview, failed preview, retry, dismiss до ответа и поздний ответ от старого preview. Количество **и значения** записей/экспортируемых payload entries должны остаться прежними. Не сравнивать байты всего export, если metadata содержит новое время экспорта.

## 4. Начало выделения и follow

### 4.1 Пауза

Добавить `PlaybackController.pause()` и `TranscriptTextView.onSelectionBegan: () -> Void`.

Coordinator хранит `hadNonemptySelection` и `isApplyingProgrammaticUpdate`. Все изменения text/attributed text/selectedRange из кода оборачивать guard-флагом; после замены документа синхронизировать сохранённую длину selection. `textViewDidChangeSelection` сам по себе не доказывает действие пользователя.

В delegate: вне программного обновления, при переходе empty → nonempty вызвать callback один раз и выключить follow. Дальнейшее движение handles не вызывает повторную паузу. При empty сбросить `hadNonemptySelection`. Подсветка cue меняет background attribute, не `selectedRange`. Не использовать readonly `shouldChangeTextIn` и не перехватывать long-press жестом, мешающим нативному меню.

Reader callback: `playback.pause(); following = false`. Не делать `toggle()` — он может включить остановленное аудио. Обновление SwiftUI bindings из `updateUIView` при необходимости отложить на main run loop и проверить актуальность документа; не создавать render loop.

### 4.2 Точный алгоритм центрирования

В этой реализации выбрать TextKit 1 явно: `UITextView(usingTextLayoutManager: false)` и использовать один `layoutManager`. Не смешивать TextKit 1 glyph API с TextKit 2 fragments.

Смысл «активная строка»: первая визуальная строка активного cue. Для многострочного/очень длинного cue не центрировать середину всего блока, которая может скрыть начало. Правило едино для коротких и длинных cue.

1. Проверить range cue и завершить layout для textContainer. Найти glyph первого символа, затем `lineFragmentUsedRect` этой визуальной строки. Добавить `textContainerInset.top` к Y, чтобы получить rect в координатах содержимого UITextView.
2. Использовать значения после layout:

```text
T = adjustedContentInset.top
B = adjustedContentInset.bottom
H = bounds.height
visibleHeight = H - T - B
minY = -T
maxY = max(minY, contentSize.height - H + B)
targetY = lineRect.midY - T - visibleHeight / 2
contentOffset.y = min(max(targetY, minY), maxY)
```

Если visibleHeight <= 0 или layout не готов, отложить до layout. Горизонтальный offset не менять. Safe area повторно не вычитать: она уже отражена в bounds/insets.

3. Центрировать только когда following == true, нет непустого selection, drag/deceleration отсутствует, и изменился ключ центрирования: document revision, active cue, follow generation, width/height/insets или Dynamic Type size.
4. Добавить `followGeneration` в Reader. Нажатие Follow увеличивает generation даже при том же cue. Кнопка также **явно очищает selection** под программным guard, иначе ранний return будет вечно препятствовать возврату follow. После очистки центрировать; не запускать playback.
5. При drag выключать follow. При явном Follow остановить текущую инерционную прокрутку перед центрированием. При смене документа очистить старый highlight и selection, сбросить cached glyph/scroll indices; равенства `document.text` недостаточно, если mapping/ranges изменились.
6. Новый layout из-за rotation/Dynamic Type инициирует повторный расчёт, даже если cue не менялся. Реализовать callback из небольшого UITextView subclass после `layoutSubviews`; не выполнять асинхронный scroll со старым документом.
7. Для автоматического follow применять offset без анимации, чтобы не накапливались animations; explicit Follow также без анимации в MVP. При nil active cue (gap/TXT) не прокручивать. Для полностью untimed документа скрыть кнопку Follow.

Pure helper вычисляет offset по числовым rect/insets; UIKit integration проверяет, что туда передана первая визуальная строка. Unit-теста одной формулы недостаточно для доказательства работы TextKit.

## 5. Скорость и единый жизненный цикл phrase audio

### 5.1 PlaybackController

Добавить `PlaybackRate: Float, CaseIterable` с 0.5, 0.75, 1, 1.5, 2; `private(set) var selectedRate: PlaybackRate = .normal`, метод `setRate(_:)`, `play()`, `pause()`, сохранить `toggle()` как switch между play/pause. Не использовать `AVPlayer.rate` как хранилище настройки: при паузе он равен нулю.

- `setRate`: сохраняет выбор; при намерении воспроизведения применяет его к player; на паузе не запускает playback.
- `play`: активирует audio session существующим способом; после нужного seek запускает выбранную скорость, например `playImmediately(atRate:)`. Не вызывать далее `play()`, сбрасывающий выбранный режим на обычный.
- Ввести `wantsToPlay` отдельно от фактического `player.rate`: buffering/seek временно могут давать rate 0. Согласовать observable `isPlaying` с намерением, чтобы play/pause не менял смысл во время ожидания.
- `pause`: немедленно снимает wantsToPlay и останавливает player. Pending seek completion проверяет актуальный seek token **и** wantsToPlay, поэтому не возобновляет звук после selection pause.
- При достижении конца диапазона снять wantsToPlay/isPlaying. Следующий Play сначала seek к lower bound, ждёт актуального completion, затем запускает выбранный rate. Обработать и конец обычного item, и range end.
- `open` и `close` очищают item, observers, намерение играть и invalidate seek completions, но не меняют selectedRate. Новый экземпляр контроллера — 1×. Невалидные/non-finite позиции не передавать в CMTime.
- Сохранить текущую защиту от устаревших periodic observations и seek completions; не заменять на произвольный dispatch delay.

### 5.2 Источник и диапазон фразы

Вынести общий resolver/description для Reader preview, Dictionary detail и Learning card. До multi-track реализации он разрешает файл через `MediaImportService.directory(for:)`:

1. Найти локальный item по `localSourceItemID`, иначе по `sourceItemID` (совместимость с текущим detail).
2. Проверить существование файла, finite `0 <= start < end <= item.duration`; отсутствующий/невалидный диапазон означает Audio unavailable.
3. Не обращаться к сети и не подставлять первое media из библиотеки. Portable dictionary без локального источника продолжает работать текстом.
4. Владелец playback запоминает identity `(item.id, URL, start, end)`. При первом Play/новой identity открыть диапазон; при pause/resume той же identity не переоткрывать файл. В конце диапазона повтор начинается с начала по правилу controller.

LearningSession владеет одним контроллером на весь открытый экран. Закрывать audio при answer, skip, restart, открытии edit/detail sheet и onDisappear, включая Close. Preview/detail тоже закрывают audio на dismiss. Не запускать два контроллера одновременно.

Кнопка audio на учебной карточке доступна **только после Check**, чтобы не раскрывать оригинал звуком до ответа. Если файла нет, после раскрытия показывать «Audio unavailable on this device». Скорость рядом с доступным audio. Reader и dictionary detail имеют те же 5 значений, preview также использует общий control, поскольку содержит player.

## 6. Раунд: инварианты и транзакция ответа

Создать чистую value-модель `LearningRoundState` в отдельном `App/Models/LearningRoundState.swift`. Удалить/заменить старый `LearningQueue.advance`, обновив все ссылки и тесты. Не хранить ModelContext/DictionaryEntry внутри состояния.

```text
selection: five | ten | twenty | all (default ten)
selectedIDs: [UUID]          // уникальный фиксированный набор, порядок старта
pendingIDs: [UUID]           // текущая карточка всегда first
completedIDs: [UUID]         // уникальные Right, порядок завершения
skippedIDs: [UUID]           // удалённые/ставшие недоступными во время раунда
wrongAttemptCount: Int
currentPresentationID: UUID // защита от повторного события на одной карточке
```

`totalSelectedCount = selectedIDs.count`, `rightAttemptCount = completedIDs.count`; не хранить изменяемые копии этих счётчиков. Все три группы pending/completed/skipped попарно не пересекаются, их объединение равно selectedIDs. В pending каждый UUID встречается максимум один раз.

### Старт

При открытии экрана показать setup, не начинать автоматически из onAppear. Варианты: 5/10/20/All available. Показать eligible count и фактическое `min(requested, eligibleCount)`. Default 10. При нуле Start disabled + описание. При Start заново получить eligible, дедуплицировать UUID, перемешать один раз и взять нужное число; новые записи не добавляются в уже идущий раунд. Для тестов подавать заранее выбранные IDs, не зависеть от случайной shuffle.

Выбор не сохраняется на диск. Repeat запускает новый eligible snapshot с прежним вариантом (All означает все **на момент Repeat**). На completion можно выбрать «Change round size» для возврата к setup. Не переиспользовать completed IDs предыдущего раунда.

### Ответ

UI позволяет отвечать только после Check. Действие передаёт ожидаемые entry ID + presentation ID. MainActor handler принимает событие только для текущей раскрытой карточки и не обрабатывает двойной tap повторно.

1. Проверить существование/eligibility текущей записи, захватить старый `learningLevel` и закрыть playback.
2. Вычислить новый level через **существующий** `LearningLevel.adjusted`, установить и вызвать `context.save()`.
3. Только после успешного save: удалить first из pending; Right добавить в completed; Wrong увеличить wrongAttemptCount и добавить тот же ID в хвост pending. Сбросить revealed, сменить presentation ID.
4. При failed save вернуть старый level, оставить очередь/счётчики/revealed прежними и показать ошибку с возможностью повторить. Не вызывать общий rollback, отменяющий чужие несохранённые edits.
5. При удалённой/неeligible записи выполнить skip: убрать из pending, добавить в skipped, не менять level/Right/Wrong, сменить presentation ID. Не заполнять освободившееся место новой записью. Проверять перед показом/ответом, а не фильтровать заново весь selected snapshot.

Один успешный ответ завершает запись **в этом раунде**, даже если level перешёл 1→2. Нельзя повторять Right до достижения 4: это изменяет продуктовую модель.

Пример, который должен совпасть буквально:

```text
selected=[A,B], pending=[A,B], completed=[], wrong=0, N=2
Wrong(A): pending=[B,A], completed=[], wrong=1, N=2
Right(B): pending=[A], completed=[B], wrong=1, N=2
Right(A): pending=[], completed=[B,A], wrong=1, N=2
```

Wrong при одном pending `[A]` оставляет `[A]`, но создаёт новую presentation и снова скрывает ответ. Раунд допускает любое число ошибок; Close всегда доступен. Не обещать максимум N показов.

### Счётчик и completion

В карточке показывать `Completed X of N`; отдельно `Wrong attempts: W`, `Skipped: S` при S > 0. Не называть X «globally learnt». Цвет не является единственным носителем значения.

Раунд завершён, когда pending пуст и стартовый набор непуст. При skips заголовок «Round finished», иначе «Round complete». Показать выбранный вариант, фактическое N, completed, wrong attempts и skipped.

Ниже отдельный список **“All learnt phrases”** по свежим SwiftData данным:

```text
learningLevel == 4
&& targetLanguageCode == "ru"
&& translationStatus == .ready
&& hasTranslation
```

Не использовать `isLearningEligible`: оно исключает level 4. Сортировать createdAt descending, затем UUID string для стабильного tie-break. Старые level-4 записи включать. Right, поднявший 1→2, в список не включать. После save 3→4 новая запись появляется. Если список пуст — «No phrases at level 4 yet». Показывать original + translation, Copy и открытие существующего detail; detail сохраняет обычные editing semantics. В долгом списке использовать List/LazyVStack и прокрутку, а не непрокручиваемый VStack.

## 7. Порядок карточек, Copy и доступность

Dictionary detail: **Russian translation → Original → Audio → Source context → Progress**, затем существующие Meaning in context, Word-by-word help, Your interpretation, Source, Automatic translation. Сохранить edit/replace-confirmation/error/lookup callbacks и accessibility IDs. Перестановка секций не должна автоматически вызывать contextual translation или definition lookup.

Learning: translation → Edit translation → Check; после Check original → audio/rate → source context → Wrong/Right. Translation copy доступно до Check; copy original/context только после Check. Не раскрывать ответ accessibility label скрытой кнопки.

Создать `App/Views/CopyButton.swift`: текст/label/identifier как вход; единственная запись `UIPasteboard.general.string = value`; не читать чужой pasteboard. Inline «Copied» на 1.5 секунды, новый tap обновляет token таймера; старый timer не сбрасывает новое подтверждение. Accessibility label «Copy translation» и подобные конкретные подписи; удобная touch target, VoiceOver confirmation. Без modal alert.

Точный scope:

- Reader: сохранить системное Copy в `suggestedActions`; не добавлять дублирующее Copy и кнопки всего транскрипта/текущего cue.
- Detail: original, основной translation, source context, selected-text translation, sentence translation, word-help source и translation, непустые saved interpretation/note. Не копировать placeholder/loading/error labels.
- Learning: translation, revealed original/context и оба значения в completion list.
- Dictionary list: оставить переход в detail; не требуется новая row menu.
- Preview: original и готовые phrase/sentence translations, source sentence.

Copy передаёт полный показанный plain text без section title, форматирующих атрибутов и дополнительной нормализации. Сохранить `.textSelection(.enabled)` там, где оно уже есть; кнопка дополняет его. На editable TextEditor использовать системное Copy, не создавать конфликтующий overlay.

## 8. Порядок реализации и проверяемые задания

Каждое задание завершать своей проверкой, затем переходить дальше. Не реализовывать все пункты одним неразделённым изменением.

1. **Selection + preview:** согласовать expanded range, value DTO, отдельный coordinator/view, branching Reader. Проверить отсутствие мутаций SwiftData/export и stale-response race. Не менять старый persisted coordinator без отдельной необходимости.
2. **Playback foundation:** selected rate, play/pause intent, seek guards, phrase source resolver. Подключить Reader/detail/preview. Проверить pause/resume, rate во время pause, end replay, смену файла и stale seek completion.
3. **Selection pause + follow:** delegate guard, follow generation, TextKit layout hook/формула. UIKit checks для выбора, первой/последней строки, длинного cue, identical text с новым mapping, rotation/Dynamic Type.
4. **Pure round model:** инварианты и конкретная последовательность A/B, один элемент, повторные ошибки, duplicate event, skip и fixed count. Сохранить тесты ограничений `LearningLevel.adjusted`.
5. **Learning integration:** setup, транзакция answer, Repeat, глобальный completion query, phrase player только после Check. Failed-save тест должен доказывать отсутствие продвижения очереди.
6. **Presentation:** перестановка секций, reusable rate control/Copy, scrollable cards. Не создавать слой пользовательских настроек: в этой задаче нет постоянных настроек.
7. **Integration gate:** существующие unit/UI tests плюс новые fixtures. Запустить `bash scripts/test.sh` при реализации; `project.yml` — источник проекта, генерируемый `.xcodeproj` вручную не редактировать. Для документационного ревью запуск iOS suite не требуется.

Обязательные acceptance cases:

| Область | Проверка результата |
|---|---|
| Preview | Success/failure/dismiss/retry не изменяют записи; selection/audio используют один expanded range; нет word-help side effects. |
| Follow | Offset helper: first/middle/last/short content/asymmetric insets. UIKit: первая visual line около центра с точностью 2 pt, кроме clamped края; нет scroll при selection/gap/TXT. |
| Selection | Play → user selection → pause один раз; move handles не повторяет callback; highlight/programmatic document reset не вызывают pause. Follow очищает selection, центрирует, не возобновляет звук. |
| Round | 5/10/20/all и available=0/3/25; Wrong не увеличивает N; один Right удаляет из pending; duplicate tap не меняет следующий entry; failed save не продвигает. |
| Completion | Previously learnt C входит; A с 1→2 отсутствует; B с 3→4 входит. Missing/unsupported/pending translations фильтруются; Right/Wrong остаются статистикой раунда. |
| Audio | До Check нет кнопки/озвучиваемого ответа; pause/resume не возвращается к start; следующий entry не играет старый clip; missing local file безопасен. |
| Rate | Новый controller 1×; выбор 0.75× в pause не запускает звук; следующий Play 0.75×; open/close сохраняют 0.75×; другой controller 1×. |
| Copy/layout | Exact copied content, nonmodal confirmation; iPhone/iPad, portrait/landscape, dark/light, largest Dynamic Type, VoiceOver, Reduce Motion. |

UI-тесты Apple Translation использовать с injected fake responses: стабильные тесты не должны зависеть от сети/установленного language pack. Отдельно вручную проверить supported/installed/download/unsupported состояния на поддерживаемой ОС. Для AVPlayer проверить реальный bundled fixture и собственный state-machine fake; один тест enum rates не доказывает воспроизведение с выбранной скоростью.

## 9. Связь с другими планами и knowledgebase

Этот план реализовать **до** `MULTI_TRACK_AUDIOBOOK_ARCHITECTURE.md`: здесь вводятся устойчивые playback intent/rate, ephemeral preview и state раунда. Multi-track затем меняет source resolution и timeline, сохраняя эти semantics. AWS не является зависимостью этой задачи.

В implementation PR обновить `knowledgebase/CHANGELOG.md` и `DECISIONS.md`: transient preview, fixed unique round semantics, глобальный список learnt и session-local rate. PROJECT менять только при фактическом изменении major workflow; явно отметить отсутствие изменения purpose/boundaries, если они прежние. Не описывать план как уже выпущенную возможность.

Ссылки для API-проверки при реализации: [UITextView layout system](https://developer.apple.com/documentation/uikit/uitextview/init(usingtextlayoutmanager:)), [selection delegate](https://developer.apple.com/documentation/uikit/uitextviewdelegate/textviewdidchangeselection(_:)), [AVPlayer selected-rate playback](https://developer.apple.com/documentation/avfoundation/avplayer/playimmediately(atrate:)), [TranslationSession](https://developer.apple.com/documentation/translation/translationsession). Поведение собственных классов выше проверено по репозиторию, а не выведено из этих API-ссылок.
