# Архитектура многотрековых аудиокниг

**Статус:** проверенная постановка, не реализованная возможность.  
**Ревью:** 2026-09-22, по текущим моделям, importer, reader, playback, dictionary transfer и subtitle-aligner.

## 1. Решение и исправления исходного черновика

Одна книга — один `LearningItem`, содержащий упорядоченные **физические аудиотреки**. Subtitle cue хранится в локальном времени трека; глобальное время вычисляется по длительностям. Существующий `LearningPart` остаётся виртуальным диапазоном одного legacy-файла и не переименовывается в track.

| Неоднозначность/ошибка черновика | Решение |
|---|---|
| `order` и порядок массива одновременно | В manifest порядок задаёт только массив `tracks`. Поля `order` нет. Не пересортировывать manifest по имени. |
| globalStart, общая duration и local duration как независимые данные | globalStart и total duration вычисляются из проверенных длительностей треков. Не хранить редактируемые offsets. |
| «Локальные timestamps начинаются с нуля» | Ноль — начало файла. Первый cue может начаться позже из-за тишины. Не сдвигать cue к нулю. |
| Один TXT без границ показывается как текст текущего трека | При неизвестных границах показывать **весь TXT** как untimed reading, независимо от выбранного трека; не приписывать ему audio range. |
| Track-aware dictionary отложен до этапа 2 | Любой показ timed multi-track transcript требует track-aware source с самого начала. Иначе сохраняется неверный audio. |
| Adapter гарантирует migration | Adapter решает чтение бизнес-модели, но не проверяет открытие старого SwiftData store. Нужен on-disk upgrade fixture и отдельный migration gate. |
| `align.py --manifest` без изменения обязательных аргументов | Добавить отдельный `batch_align.py`. Сохранить single-file CLI и его required `--audio`/`--text`. |
| Все диапазоны можно получить из порядка MP3 | Нельзя. Автоматическое обнаружение границ TXT не входит в MVP. Batch принимает только явно размеченные диапазоны. |
| «Транзакционный» move + SwiftData save | Это две разные системы. Использовать staging, compensation и crash-recovery journal, не обещать одну атомарную транзакцию. |

Целевой пример из исходного описания — `orwel-1984`, TXT и ZIP с 28 MP3 `001`–`028`. Эти медиа **не найдены в репозитории при ревью**; не считать их проверенным fixture и не скачивать/коммитить книгу. Разработать синтетические короткие аудио и текст; проверка реальной книги возможна отдельно при её наличии.

## 2. Границы MVP и зависимости

Сначала реализовать `IMPLEMENTATION_PLAN_LEARNING_UX.md`, либо явно перенести и проверить его foundations перед этой задачей: playback intent/rate/seek generations, единый phrase resolver, ephemeral preview. Multi-track расширяет их, не создаёт второй несовместимый player.

Включить:

- local ZIP import: manifest package или обычный ZIP с аудио и одним TXT внутри/выбранным отдельно;
- 1–100 audio tracks, local transcript/timing, последовательное воспроизведение, глобальный seek, local progress;
- plain TXT чтение; per-track SRT/VTT при явной привязке;
- legacy audio/video, virtual parts и словарь без потери данных;
- local batch alignment по явно заданным диапазонам одного TXT.

Отложить: folder picker, multi-select отдельных аудио, cloud multi-track processing, concatenation audio, gapless guarantee, global SRT import/export, автоматическое разбиение TXT, редактирование/удаление/замена треков после импорта, перенос audiobook progress между устройствами. Будущие работы перечислять в общем `FUTURE_IMPROVEMENTS.md`.

AWS-план независим: его контракт — **одна запись до 60 минут**, не ZIP и не книга. Не отправлять много треков туда скрыто и не применять один SRT к каждому файлу.

## 3. Контракт package v1

Основной формат — ZIP, `.book.zip` является соглашением имени, а не доверенным доказательством формата. UTF-8 `manifest.json` лежит строго в корне:

```text
example.book.zip
  manifest.json
  transcript.txt
  audio/001.mp3
  audio/002.mp3
  subtitles/001.srt
```

Пример **неполностью синхронизированной** книги:

```json
{
  "format": "foreign-language-learner.book",
  "schemaVersion": 1,
  "title": "Example book",
  "sourceLanguage": "pl",
  "transcript": "transcript.txt",
  "tracks": [
    {
      "id": "001",
      "title": "Chapter 1",
      "audio": "audio/001.mp3",
      "alignmentStatus": "aligned",
      "subtitle": "subtitles/001.srt"
    },
    {
      "id": "002",
      "title": "Chapter 2",
      "audio": "audio/002.mp3",
      "alignmentStatus": "untimed"
    }
  ]
}
```

Создать `docs/book.schema.json` **во время реализации** и Swift/Python validators для одинаковых fixtures. Правила v1:

- `format`/`schemaVersion` обязательны и равны примеру. Неизвестную версию отклонять. Неизвестные поля отклонять, чтобы опечатка вроде `subtitles` не теряла связь молча.
- title — непустой после trim, максимум 500 Unicode scalars. sourceLanguage — непустой language tag, максимум 64 ASCII символа; сохранить код даже без поддержки Apple Translation, не блокировать чтение книги из-за переводчика.
- transcript — обязательный путь к одному nonempty UTF-8 TXT <= 10,000,000 bytes.
- tracks: 1–100 записей; ID уникален внутри книги, case-sensitive ASCII `[A-Za-z0-9_-]{1,64}`, порядок — массив. ID не зависит от позиции и после импорта неизменяем.
- Каждый track: обязательные id/title/audio/alignmentStatus. Audio extensions `mp3`, `m4a`, `wav` case-insensitive; duration получать через AVAsset, manifest duration не принимать как истину. Одинаковый audio path в нескольких tracks отклонять.
- `alignmentStatus`: `aligned`, `review-required`, `untimed`. Первые два требуют subtitle; untimed запрещает subtitle. `failed` принадлежит batch report, **не импортируемому package**.
- subtitle — один SRT **или** VTT, не оба. UTF-8, строго < 10,000,000 bytes. Parse через существующий `TranscriptParser`; все cues timed, finite, `0 <= start < end`, конец <= duration + 0.100 секунды. Overlapping cues разрешены: сохранить существующее правило «last-started wins». Требования к generated alignment строже, чем к стороннему импорту; не ломать legacy parser ради batch.
- После stable sort по start равные start сохраняют порядок файла, поэтому last-started rule детерминирован. Требуется явно стабильная сортировка по `(start, originalIndex)`, не предполагать stable `sorted` без tie-break.
- Дополнительные optional поля для batch: top-level `textMapping` и per-track `textRange`, строго по разделу 9. Не использовать их как секунды или UTF-16 offsets.
- Состояние книги вычислять: все aligned → Synced; все timed и есть review → Review required; timed+untimed → Partly synced (отдельно review badge при наличии); все untimed → Untimed. Не показывать всю книгу Synced при одном хорошем треке.
- `aligned` от внешнего manifest означает наличие валидных timings, а не доказательство совпадения редакции/слов. UI предупреждает, что import не оценивает качество alignment.

Хранение после импорта использует генерируемые имена, а не archive paths:

```text
Library/<new local item UUID>/
  transcript.txt
  audio/<track id>.<approved extension>
  subtitles/<track id>.srt|vtt
  manifest.json
```

Локальный item UUID создавать новый при каждом импорте, даже того же package. Track IDs сохранять из manifest. Ключ источника — `(local item UUID, track ID)`; не дедуплицировать книги по title/filename.

## 4. Обычный ZIP и preview

Без корневого manifest:

1. Проверить архив до извлечения. Найти поддерживаемое аудио во вложенных папках. `.DS_Store`, `__MACOSX`, dot-prefixed entries игнорировать после проверки безопасности путей.
2. Использовать natural sort только для **предложения** порядка: `localizedStandardCompare` по относительному пути, tie-break по исходным UTF-8 bytes. Это удобный локальный preview, не переносимый источник истины; сохранить подтверждённый порядок в generated manifest.
3. Показать filename/path/title, size, duration и drag reorder. Всегда требуется явное Import после preview. Не анализировать ID3 для скрытого изменения порядка.
4. При одном TXT выбрать его; при нескольких дать выбрать один; при нуле открыть отдельный TXT picker. Не выбирать «первый найденный» и не считать README текстом книги без подтверждения.
5. Сторонние SRT/VTT без manifest **не связывать по похожим именам**. Показать «Subtitles require a book manifest»; raw ZIP import остаётся untimed. Остальные файлы не извлекать и показать их число как ignored.
6. Присвоить новым tracks UUID strings при создании preview. Reorder меняет массив, не IDs. Title редактируется; файлы не переименовываются по введённому title.

Manifest package: порядок/связи из manifest, preview их показывает; в MVP разрешить менять book title, но не reorder manifest tracks с text mappings. Это исключает разрушение связи с каноническим TXT. Изменение упаковки выполняется внешним инструментом.

Не реализовывать folder picker в том же PR «по возможности». Обычный ZIP + отдельный TXT уже покрывает описанный исходный пример.

## 5. Модель данных и migration gate

### 5.1 Аддитивная модель

Для ограниченного MVP выбрать Codable metadata-массив, не отдельную SwiftData relationship. Не хранить массивы cues каждого трека внутри этого массива: subtitle-файлы — источник, parser cache загружает только текущий трек. Это исключает сериализацию всех cues при каждом progress save.

Добавить к `LearningItem`, сохраняя **все** существующие поля/типы/defaults:

```swift
var tracks: [LearningTrack] = []
var lastTrackID: String? = nil
```

```swift
struct LearningTrack: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var mediaFilename: String        // relative generated path
    var subtitleFilename: String?
    var duration: Double             // finite, > 0, AVAsset verified
    var alignmentStatus: TrackAlignmentStatus
    var lastPosition: Double        // local seconds, initial 0
    var isCompleted: Bool           // manual flag, initial false
}
```

Новые multi-track imports: `mediaKind="audio"`, `mediaFilename=""` (legacy-only sentinel), `transcriptFilename="transcript.txt"`, `segments=[]`, `parts=[]`, `duration=sum(track.duration)`, lastPosition=0. Все consumers обязаны пройти через adapter прежде, чем такие записи можно создавать. **Запретить** fallback на `mediaFilename` для nonempty tracks, иначе откроется каталог вместо файла.

`duration`/`lastPosition` остаются совместимым summary для library, но source of truth multi-track — durations и `(lastTrackID, track.lastPosition)`. При save/open recompute summary; не читать устаревший global lastPosition вместо local progress. `globalStart`/`order` в хранилище не добавлять. Обновлять progress заменой value в массиве по ID, а не мутировать временную копию.

### 5.2 Legacy adapter

`tracks.isEmpty` означает legacy item. `BookMediaDescriptor` представляет его одним synthetic track с ID `legacy`, исходными filename/duration/segments. Стабильный ID — константа **внутри item**, не новый UUID при каждом чтении. Adapter не записывает ничего в старую модель и не перемещает файлы.

Legacy `LearningPart`/Reader part picker продолжают использовать прежний диапазон внутри единственного файла. Не преобразовывать parts в tracks. Legacy video остаётся `VideoPlayer`; multi-track import — audio-only. Никаких новых virtual parts для multi-track MVP.

Добавить `sourceTrackID: String? = nil` в DictionaryEntry. Существующие `audioStart/audioEnd` переиспользовать как local seconds **только вместе с новым nonnil sourceTrackID**. Не переименовывать старые колонки и не заводить дублирующие localAudioStart/End:

- sourceTrackID nil + legacy item → существующие абсолютные секунды единственного файла;
- sourceTrackID nonnil → найти ровно этот трек и трактовать start/end локально;
- sourceTrackID nil + multi-track item → audio unavailable, никогда не угадывать первый трек.

### 5.3 Реальное обновление store

До изменения `LibraryModels.swift` создать on-disk fixture текущей схемой (не `inMemory: true`): legacy audio, video, parts/completion/progress, dictionary with context/audio/translation/wordHelp. Записать baseline values и UUID.

Сначала проверить аддитивную automatic migration на старом store. Если supported migration не проходит, ввести явные VersionedSchema/SchemaMigrationPlan с прежней и новой схемами, воспроизводя старые entity/field identities; не менять схему fixture на новую, чтобы «починить» тест. Не удалять пользовательский store и не включать fallback на пустой/in-memory store при ошибке.

Gate: старый store открывается новой app → значения/IDs/parts сохраняются → legacy файлы играют → новый multi-track item сохраняется → закрытие/повторное открытие сохраняет обе разновидности. Ошибка migration показывает recoverable error и оставляет файлы/БД доступными для восстановления. Downgrade на старую app с новыми multi-track данными не гарантируется; не обещать его.

## 6. Timeline и playback

### 6.1 Чистый resolver

Создать `BookTimeline.swift` без AVPlayer/SwiftData. Длительности finite и > 0. Сумма тоже finite. `offset[0]=0`, `offset[i]=sum(duration[0..<i])`, `total=sum(duration)`.

Для seek принимать finite seconds, clamp в `[0,total]`. Интервалы **полуоткрытые** `[offset, offset+duration)`: точная граница принадлежит следующему треку. Исключение `t == total` → последний трек, localTime=его duration; это не первый трек. NaN/±infinity отклонять.

```text
tracks durations [60,90,30], total=180
seek 0   -> track 1, local 0
seek 59  -> track 1, local 59
seek 60  -> track 2, local 0
seek 149 -> track 2, local 89
seek 150 -> track 3, local 0
seek 180 -> track 3, local 30
```

Не округлять длительности до секунд/миллисекунд перед суммированием. CMTime преобразовать на AVPlayer boundary; UI округляет только подпись. AVFoundation decoder duration, а не MP3 bitrate/размер, задаёт offsets.

### 6.2 Controller responsibilities

Сохранить `PlaybackController` как player одного файла/диапазона. Добавить `BookPlaybackController` для последовательности: владеет **одним** PlaybackController, activeTrackID, localPosition, вычисляемым globalPosition и wantsToPlay. Ни AVQueuePlayer, ни gapless preloading в MVP.

- Открытие книги: восстановить lastTrackID и его localPosition, clamp; если ID отсутствует, выбрать первый и 0. Не запускать playback автоматически.
- Play на последнем track при global end: перейти к первому track local 0 и играть. Play в другом месте продолжает оттуда.
- Cross-track seek: запомнить wantsToPlay и selectedRate; увеличить book generation; сохранить старую local position; закрыть старый item; открыть нужный; выполнить seek; продолжить только после completion, если generation/track ID актуальны и wantsToPlay всё ещё true.
- Pause во время seek снимает wantsToPlay; поздний completion не возобновляет звук. Не проверять только текущий `player.rate`, который при загрузке равен нулю.
- End notification принимать только для текущего AVPlayerItem + book generation. Если playing и есть следующий — сохранить текущую позицию duration, открыть следующий **с 0**, даже если его сохранённая позиция иная, и продолжить. Если последний — сохранить total, остановиться. Один notification не может переключить дважды.
- При ручном выборе трека открывать его сохранённую localPosition; при global slider seek — вычисленную позицию; эти действия имеют разные правила.
- Phrase playback в detail/learning/preview использует single-file controller с range; не запускает BookPlaybackController и не переходит к следующему track после конца phrase.
- На ошибке открытия/декодирования остановиться и показать track title + retry; не пропускать track молча. Close удаляет observers и invalidate callbacks до смены файла.
- Искусственную паузу не добавлять. Замена AVPlayerItem может создать слышимый gap; «без дополнительных пауз» не означает гарантированный gapless.

Сохранять local progress каждые 5 секунд изменения **медиа-времени**, при смене трека, scene inactive и onDisappear; также lastTrackID/summary global position. Не переписывать subtitle cache в SwiftData. isCompleted — ручная отметка; автопереход сам её не выставляет.

## 7. Transcript, selection, dictionary и удаление

### 7.1 Два режима чтения

Reader для multi-track имеет «Track transcript» и «Full text»:

- Если текущий трек timed, default Track transcript показывает только его parsed cues в local seconds; active cue считается по localPosition. Cache key `(item.id, track.id, subtitle path)`; не rebuild/parser каждый playback tick.
- Если текущий трек untimed, Track transcript показывает «No timed transcript for this track» и кнопку Full text. Не показывать соседние cues под новым аудио.
- Full text показывает один общий TXT как untimed/selectable, без timed highlight/follow и без audio range для selection, даже если сейчас играет конкретный трек. Его reading scroll живёт в текущем view; cross-launch text scroll restoration отложен.
- Full text mode сохранять при автоматическом переходе audio track, чтобы не сбрасывать чтение. В Track transcript mode переход обновляет документ/track identity и сбрасывает selection/highlight/follow cache по правилам UX-плана.
- Каждый selection payload содержит snapshot itemID/trackID/documentRevision + range. Если меню от старого документа выполняется после switch, отвергнуть действие и предложить выбрать текст снова. Не читать текущий track ID для старого range.
- Selection через границу треков не поддерживается, поскольку timed view содержит только текущий трек. Cross-cue selection внутри него поддерживается. Full text selection может пересекать текстовые главы, но остаётся без аудио.

### 7.2 Dictionary source

При timed selection сохранить sourceTrackID, первый/последний затронутые local cue times и существующий bounded tail 0.75 секунды, ограниченный текущей track.duration и следующей cue boundary. Не прибавлять globalStart при сохранении. segmentIndex относится только к указанному треку.

Phrase resolver из UX-плана расширить через BookMediaDescriptor. Искать source item по текущему localSourceItemID/sourceItemID правилу, затем строго sourceTrackID. Невалидные times/missing media/missing ID → Audio unavailable, текст/перевод остаются читаемыми.

**Dictionary JSON v1 остаётся прежним:** текущий transfer не экспортирует ни audioStart/End, ни localSourceItemID. sourceTrackID тоже не экспортировать в этом scope. Новый импорт JSON создаёт текстовую запись без audio link; update translations сохраняет существующие local audio/track metadata. Не заявлять переносимость phrase audio между устройствами. Проверить roundtrip и translation-only merge, чтобы добавление поля не обнулило локальные ссылки.

### 7.3 Library deletion

Текущий `ContentView.deleteItems` удаляет связанные локальные dictionary entries вместе с item. Это отдельное существующее поведение; multi-track PR не должен незаметно менять его на сохранение всех entries. Применить тот же scope к целой книге, включая все track files. Общее улучшение политики удаления/сохранения словаря вынесено в future backlog.

Но текущий порядок file deletion → DB save не восстанавливает файлы после failed save. В новом file transaction service использовать обратимый move в `LibraryTrash/<transaction UUID>` + journal, затем save. При save failure вернуть каталог; при успехе очистить trash. После crash определить commit по наличию item в БД: item существует → восстановить, отсутствует → удалить trash. Не считать database rollback восстановлением физического файла.

## 8. Archive importer, лимиты и crash recovery

Новый `BookImportService` actor выполняет файловые/AVAsset операции и возвращает Sendable value result. SwiftData insert/save делает MainActor coordinator. Не передавать ModelContext/managed objects в detached work.

Начальные **ограничения реализации** (константы одного `BookImportLimits`, с boundary tests): ZIP <= 4 GiB, суммарно извлекаемые файлы <= 8 GiB, один audio <= 2 GiB, 1–100 tracks, <= 1,000 archive entries включая ignored, manifest <= 1 MiB, TXT <= 10,000,000 bytes, каждый subtitle < 10,000,000 bytes, суммарные subtitle bytes <= 50,000,000. Не поднимать эти limits без memory/disk проверки; локальная книга не наследует AWS duration limit.

Выбрать ZIPFoundation через Swift Package Manager, объявленный в `project.yml`; при реализации закрепить проверенный release/commit и лицензию, не плавающую development branch. Использовать streaming entry extraction с consumer: высокоуровневое «unzip всё» не обеспечивает наши лимиты само по себе. [Проект ZIPFoundation](https://github.com/weichsel/ZIPFoundation), [consumer extraction API](https://raw.githubusercontent.com/weichsel/ZIPFoundation/development/Sources/ZIPFoundation/Archive%2BReading.swift).

До извлечения:

1. Скопировать выбранный ZIP под security-scoped доступом в приватный staging; провайдерский URL не хранить как постоянный путь. Проверить размер до копирования и фактические bytes во время него.
2. Перебрать каталог entries с ограничением количества. Разрешать только regular file/directory; symlink, special entries, encrypted/unsupported/malformed ZIP отклонять. Не исполнять ничего из архива.
3. Проверить **все** пути, включая ignored: запретить absolute, `..`, `.`, empty interior components, обратные слеши, NUL/control, Windows drive prefix. Не URL-decode архивные имена. Reject дубликаты после NFC + casefold и file/directory collisions; это предотвращает перезапись на case-insensitive filesystem.
4. Strict manifest package: извлекать только manifest/transcript/referenced media/subtitles; неизвестные обычные файлы отклонять, разрешённые системные metadata игнорировать. В raw ZIP показать ignored count и извлекать только выбранные files. Не поддерживать nested archives.
5. Проверить объявленные размеры, available capacity и резерв 256 MiB сверх оставшегося объёма извлечения. Во время streaming считать фактические decoded bytes по entry и суммарно; при превышении сразу отменять. Проверить полученный CRC против entry.checksum — одного вычисления CRC без сравнения недостаточно. Лимит ratio не нужен как единственная защита: абсолютные decoded limits обязательны.
6. Извлекать в новые **генерируемые** пути staging, без перезаписи существующих. Проверять destination containment по path components, не `hasPrefix` строки. Запретить links в staging, не переносить произвольные permissions/ownership attributes из ZIP.
7. Probe audio последовательно/с concurrency максимум 2, проверять playable/finite positive duration; обложка внутри MP3 не должна считаться видеокнигой. Не загружать все аудио в RAM. Проверять TXT/subtitles/manifest до commit.

Staging находится в Application Support `ImportStaging/<transaction UUID>` на том же volume, что Library, исключён из backup. Для долгой распаковки — progress/cancel, cancellation check между chunks; без обещания продолжения после force-quit.

Commit protocol (не менять порядок):

```text
validate preview and extracted files
write durable journal {transactionID, itemID, stagingPath, finalPath, state: prepared}
rename staged book directory -> Library/<itemID> (destination must not exist)
insert complete LearningItem and save ModelContext
mark journal committed
remove staging ZIP and journal
```

При ошибке save удалить вставленный item из context и убрать/вернуть moved directory, не трогая чужие items. При запуске recovery до показа незавершённых imports: если journal itemID есть в БД и final directory существует — оставить данные, убрать staging/journal; если itemID отсутствует — удалить только каталог из проверенного journal и staging; если запись есть, а final отсутствует — показать repair error, не удалять запись молча. Journal paths восстанавливать из validated IDs, не доверять произвольным абсолютным путям в JSON. Не удалять каталоги без journal только потому, что model fetch завершился ошибкой.

После успешного импорта файлы неизменяемы в MVP. Обновление/замена/переупаковка существующей книги — отдельная миграция, а не overwrite by title.

## 9. Batch alignment: точный контракт текста и rerun

Добавить `tools/subtitle-aligner/batch_align.py`:

```sh
python3 tools/subtitle-aligner/batch_align.py \
  --manifest /path/to/unpacked-book/manifest.json \
  --output /path/to/new-batch-output
```

Вход — unpacked directory с тем же schema, все paths относительны manifest directory и не выходят из него. Этот CLI не распаковывает произвольный ZIP. Single CLI `align.py` остаётся прежним.

Для batch обязательны:

```json
{
  "textMapping": {
    "normalization": "aligner-nfc-whitespace-v1",
    "normalizedSHA256": "<64 lowercase hex>",
    "wordCount": 3500
  }
}
```

И на каждом track:

```json
{ "textRange": { "startWord": 0, "endWord": 1842 } }
```

Это дополнения к полному manifest, не отдельные валидные manifests. При обычном iOS import ranges optional. Если textMapping присутствует, все tracks должны иметь range; обратное тоже обязательно.

Normalization v1 точно повторяет текущий `clean_text`:

1. удалить все U+FEFF;
2. Unicode NFC;
3. разбить по whitespace и соединить single ASCII space, без leading/trailing;
4. tokens — split нормализованной строки по ASCII space, punctuation остаётся частью token;
5. checksum — SHA-256 UTF-8 нормализованной строки **без завершающего newline**.

Для идентичности Python/Swift явно зафиксировать whitespace set: U+0009–000D, U+001C–001F, U+0020, U+0085, U+00A0, U+1680, U+2000–200A, U+2028, U+2029, U+202F, U+205F, U+3000. Не использовать NLTokenizer/Swift words для этих индексов. Добавить общий fixture с BOM, польскими combining marks, NBSP, CRLF, emoji и повторяющимися словами; сравнить нормализованные bytes, hash и извлечённые slices в Swift/Python.

Диапазоны 0-based полуоткрытые `[startWord,endWord)`; целые числа, `0 <= start < end <= wordCount`. В порядке tracks: первый start=0, каждый следующий start=предыдущий end, последний end=wordCount. Это полное покрытие без gaps/overlaps. Если диктор пропустил предисловие или TXT другой редакции, подготовить соответствующий TXT явно; не «исправлять» это автоматическим отбрасыванием текста. iOS validator проверяет mapping/hash/coverage при наличии, но не выводит из слов индексы секунд.

### Обработка и публикация

- Сначала валидировать **все** пути, ranges/hash и audio metadata. Если preflight не прошёл, не запускать model.
- Sequential по manifest order, один loaded model по возможности через небольшой совместимый refactor single-track core; не менять алгоритм ради batch. Не запускать 28 subprocesses параллельно и не держать все decoded waveforms в RAM.
- Каждому track передать отдельный TXT slice, local audio, offset=0, current stable-ts/profile settings. При `--allow-untimed-words` сохранять существующие review semantics; duplicate repair тоже требует review.
- Новый output каталог обязателен. `tracks/<id>/` содержит subtitles.srt/vtt, alignment.json/normalized.txt и доступные diagnostics. `batch-report.json` содержит по каждому track aligned/review-required/failed и стабильную ошибку.
- При deterministic failure одного track продолжить независимые tracks ради полного report. Exit 1, если есть хотя бы один failed; **не создавать финальный импортируемый package/manifest успешной книги**. Успешные artifacts остаются для явного rerun. Наличие частичных файлов не означает импортируемую aligned book.
- Если все tracks aligned/review-required — exit 0, собрать `book/` directory с audio копиями, transcript, SRT по tracks и финальным manifest. Review warning явно сохранить. Archive `.book.zip` создавать из book/ с проверенным layout; diagnostics/report оставить рядом, не добавлять неописанные поля/файлы в strict package.
- Copy audio bytes без транскодирования/MP3 concatenation. Не использовать `--offset` для прибавления globalStart. Times local; первый cue не обязан начинаться с нуля.

### Явный rerun одного трека

```sh
python3 tools/subtitle-aligner/batch_align.py \
  --manifest /path/to/unpacked-book/manifest.json \
  --previous-output /path/to/previous-batch-output \
  --track-id 008 \
  --output /path/to/new-batch-output
```

Перед reuse сравнить для каждого **невыбранного** трека hash audio bytes, normalized slice, language, model weights digest, stable-ts/core version и параметры группировки/validation. Неизвестная версия/несовпадение/отсутствующий успешный artifact → ошибка с перечнем требующих обработки IDs; не использовать stale subtitles. Выбранный track всегда выровнять заново. Копировать валидные предыдущие artifacts в новый output, не менять старый output. Если остаётся failed track, новый run всё ещё exit 1 без финального package. Review-required — валидный явный reuse с сохранением warning.

Это локальное повторное использование артефактов по явной команде; оно не разрешает server-side caching пользовательских данных в AWS-плане.

## 10. Последовательность реализации и acceptance gates

Каждый этап даёт проверяемый результат; не выпускать UI multi-track import прежде, чем source resolution готов.

1. **Контракты и чистые тесты:** manifest schema/validators/normalization fixtures, BookTimeline boundary cases, stable track identity, limits. Использовать искусственные fixtures, не полную книгу.
2. **Аддитивная storage migration + adapters:** on-disk upgrade gate; все прямые `mediaFilename`, `item.segments`, `item.duration`, `parts`, `audioStart` consumers найти через `rg` и перевести/разветвить явно. Обязательно ContentView summary/deletion, Reader, dictionary detail, learning audio, preview, import и unit/UI fixtures.
3. **Playback orchestration:** сначала fixture с тремя короткими local audio files; auto next, seeks и stale events. Затем сохранение/relaunch. Legacy video/parts должны продолжить работать.
4. **ZIP import + untimed UX:** manifest/raw ZIP preview, order/IDs, streaming limits, staging journal/save rollback/crash recovery; plain TXT не имеет audio linkage.
5. **Per-track transcript + dictionary:** lazy parser cache, local active cue, review/partial states, snapshot selection, exact track resolver и отсутствующий источник. Проверить JSON v1 не меняет формат и translations-only сохраняет local links.
6. **Batch CLI + rerun:** shared unchanged single-file semantics, strict word ranges, full report, no final package on partial failure, fingerprints for reuse.
7. **Integration/release:** `bash scripts/test.sh` и `python3 -m unittest discover -s tools/subtitle-aligner -p 'test_*.py'`; documentation/knowledgebase updates в том же implementation PR.

Обязательная матрица:

| Область | Проверка |
|---|---|
| Order | Manifest `[10,2,1]` остаётся `[10,2,1]`; raw ZIP natural suggestion `[1,2,10]`; drag сохраняет IDs. |
| Timeline | Пример 60/90/30, fractional durations, negative/oversized clamp, NaN reject, exact total не прыгает на первый трек. |
| Playback | Seek через два tracks; два быстрых seek; pause во время load; старый end notification; next начинает local 0; rate сохраняется; последняя дорожка останавливается. |
| Transcript | Трек 2 cue local 3–5 активен при global offset+3, не при global 3; leading silence не сдвигается; overlapping import сохраняет last-started rule. |
| Untimed | Весь TXT доступен; track switch не выдаёт ему timings; сохранённая phrase не получает случайный audio range. |
| Dictionary | Одинаковые cue index/time на разных tracks находят разные файлы; stale selection отвергается; nil sourceTrackID не разрешает multi-track audio; missing source не ломает text practice. |
| Migration | Старый store открывается, UUID/progress/parts/video/dictionary сохранены; repeated reopen работает; migration failure не стирает данные. |
| Archive | `../`, absolute/backslash, symlink, NFC/case collisions, duplicate paths, CRC mismatch, truncated/encrypted ZIP, oversized decoded data, >100 tracks, cancelled import и disk full оставляют прежнюю library целой. |
| Commit/delete | Fault injection до move, после move, после save, до удаления journal; failed DB save возвращает файлы; crash recovery не удаляет committed book. |
| Batch | Все 28 synthetic tracks получают report; invalid coverage отклоняется до model load; один failure не публикует package; rerun проверяет unchanged-track fingerprints. |

На реальной `1984`, если файлы предоставлены: проверить 28 tracks/порядок, первый/средний/последний и 008→009, relaunch, selection у краёв, untimed mode, failed alignment/rerun. Не утверждать качество всей книги по одному короткому fixture.

## 11. Knowledgebase и результат этапа

В implementation PR внести user-visible change в `knowledgebase/CHANGELOG.md`; в `DECISIONS.md` — local track timeline, immutable imported track identity, TXT без invented timing, legacy adapter + migration verification. `PROJECT.md` обновить, когда multi-track import действительно поддерживается. Этот review не меняет shipped boundaries и не является запуском реализации.

Проверяемый итог: архив, player, transcript и dictionary ссылаются на одну пару `(item ID, track ID)`, каждый timing имеет однозначную локальную шкалу, старые файлы/БД сохранены, а неуспешный import/alignment не маскируется успешной книгой.
