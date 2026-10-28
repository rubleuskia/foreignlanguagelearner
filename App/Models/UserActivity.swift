import Foundation
import SwiftData

/// Independent of books and dictionary rows so deletion does not erase activity.
@Model final class UserActivityEvent {
    @Attribute(.unique) var id: UUID
    var language: String
    var date: Date
    var kind: String
    var seconds: Double
    var entryID: UUID?
    var phrase: String
    var translation: String
    var fromLevel: Int
    var toLevel: Int
    var origin: String
    var reverted: Bool

    init(_ record: ActivityRecord) {
        id = record.id; language = record.language; date = record.date; kind = record.kind
        seconds = record.seconds; entryID = record.entryID; phrase = record.phrase
        translation = record.translation; fromLevel = record.fromLevel; toLevel = record.toLevel
        origin = record.origin; reverted = record.reverted
    }

    var record: ActivityRecord {
        .init(id: id, language: language, date: date, kind: kind, seconds: seconds,
              entryID: entryID, phrase: phrase, translation: translation,
              fromLevel: fromLevel, toLevel: toLevel, origin: origin, reverted: reverted)
    }
}

struct ActivityRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var language: String
    var date: Date
    var kind: String
    var seconds: Double = 0
    var entryID: UUID? = nil
    var phrase: String = ""
    var translation: String = ""
    var fromLevel: Int = 0
    var toLevel: Int = 0
    var origin: String = ""
    var reverted: Bool = false

    var isPromotion: Bool { kind == "level" && !reverted && toLevel > fromLevel }
    var isValid: Bool {
        !language.isEmpty && date.timeIntervalSince1970.isFinite && seconds.isFinite && seconds >= 0
            && ((kind == "time" && seconds <= 172_800 && entryID == nil)
                || (kind == "level" && entryID != nil && (1...4).contains(fromLevel)
                    && (1...4).contains(toLevel) && fromLevel != toLevel && seconds == 0))
    }
}

enum ActivityPeriod: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case day = "Day", week = "Week", month = "Month"
    var id: Self { self }
    var component: Calendar.Component {
        switch self { case .day: .day; case .week: .weekOfYear; case .month: .month }
    }
    func interval(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: component, for: date)!
    }
}

struct ActivityWord: Codable, Sendable, Hashable {
    let language: String
    let date: Date
    var count: Int = 1
}

struct ActivitySnapshot: Codable, Sendable {
    var words: [ActivityWord] = []
    var events: [ActivityRecord] = []
    var languageCodes: [String] = []

    static func load(container: ModelContainer) async throws -> Self {
        let task = Task.detached {
            let reader = ModelContext(container)
            reader.autosaveEnabled = false
            // Portable imports can overlap; use each language/form's earliest known date once.
            struct WordIdentity: Hashable { let language: String; let form: String }
            var first: [WordIdentity: ActivityWord] = [:]
            var canonicalCodes: [String: String] = [:]
            func remember(language: String, form: String, date: Date) {
                let code: String
                if let cached = canonicalCodes[language] { code = cached }
                else { code = SourceLanguage.canonical(language); canonicalCodes[language] = code }
                let key = WordIdentity(language: code, form: form)
                if first[key].map({ $0.date <= date }) == true { return }
                first[key] = ActivityWord(language: code, date: date)
            }
            for word in try reader.fetch(FetchDescriptor<ReadVocabularyWord>()) {
                try Task.checkCancellation()
                remember(language: word.languageCode, form: word.normalizedForm, date: word.firstLearnedAt)
            }
            for batch in try reader.fetch(FetchDescriptor<ReadVocabularyBatch>()) {
                try Task.checkCancellation()
                guard batch.tokenizerVersion == VocabularyTokenizer.version else { throw ReadingVocabularyError.changed }
                for form in try JSONDecoder().decode([String].self, from: batch.formsData) {
                    remember(language: batch.languageCode, form: form, date: batch.firstLearnedAt)
                }
            }
            // Most forms share chapter-completion timestamps. Compact them before updating charts.
            var counts: [ActivityWord: Int] = [:]
            for word in first.values { counts[word, default: 0] += 1 }
            let words = counts.map { key, count in
                ActivityWord(language: key.language, date: key.date, count: count)
            }
            let events = try reader.fetch(FetchDescriptor<UserActivityEvent>()).map(\.record)
            var bookRequest = FetchDescriptor<LearningItem>()
            bookRequest.propertiesToFetch = [\.sourceLanguageCode]
            var entryRequest = FetchDescriptor<DictionaryEntry>()
            entryRequest.propertiesToFetch = [\.sourceLanguageCode]
            let languages = Set(try reader.fetch(bookRequest).map { SourceLanguage.canonical($0.sourceLanguageCode) }
                + reader.fetch(entryRequest).map { SourceLanguage.canonical($0.sourceLanguageCode) }
                + words.map(\.language) + events.map(\.language))
            return Self(words: words, events: events, languageCodes: languages.filter { !$0.isEmpty }.sorted())
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func wordCount(language: String, interval: DateInterval, now: Date) -> Int {
        let code = SourceLanguage.canonical(language)
        return words.filter { $0.language == code && $0.date >= interval.start && $0.date < interval.end && $0.date <= now }
            .reduce(0) { $0 + $1.count }
    }

    func summary(language: String, interval: DateInterval, now: Date) -> ActivitySummary {
        let code = SourceLanguage.canonical(language)
        func includes(_ date: Date) -> Bool { date >= interval.start && date < interval.end && date <= now }
        let scoped = events.filter { $0.language == code && !$0.reverted && includes($0.date) }
        let promotions = scoped.filter(\.isPromotion)
        // One phrase may be promoted more than once. Lanes show its highest attained level.
        let highest = Dictionary(grouping: promotions, by: { $0.entryID! }).values.compactMap { records in
            records.max { a, b in a.toLevel == b.toLevel ? a.date < b.date : a.toLevel < b.toLevel }
        }.sorted { $0.date > $1.date }
        return .init(words: wordCount(language: code, interval: interval, now: now),
                     phrases: highest, promotions: promotions.count,
                     learned: Set(promotions.filter { $0.toLevel == 4 }.compactMap(\.entryID)).count,
                     seconds: scoped.filter { $0.kind == "time" }.reduce(0) { $0 + $1.seconds })
    }

    func activeDays(language: String, now: Date, calendar: Calendar) -> Set<Date> {
        let code = SourceLanguage.canonical(language)
        return Set(words.filter { $0.language == code && $0.date <= now }.map { calendar.startOfDay(for: $0.date) }
            + events.filter { $0.language == code && !$0.reverted && $0.date <= now
                && ($0.kind == "level" || $0.seconds > 0) }.map { calendar.startOfDay(for: $0.date) })
    }

    func streak(language: String, now: Date, calendar: Calendar) -> Int {
        let days = activeDays(language: language, now: now, calendar: calendar)
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) { cursor = calendar.date(byAdding: .day, value: -1, to: cursor)! }
        var count = 0
        while days.contains(cursor) {
            count += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }
}

struct ActivitySummary: Sendable {
    let words: Int
    let phrases: [ActivityRecord]
    let promotions: Int
    let learned: Int
    let seconds: Double
}

@MainActor enum ActivityHistory {
    static func levelChange(entry: DictionaryEntry, from: Int, origin: String) -> UserActivityEvent? {
        guard let context = entry.modelContext, from != entry.learningLevel else { return nil }
        let event = UserActivityEvent(.init(language: SourceLanguage.canonical(entry.sourceLanguageCode),
            date: entry.levelChangedAt ?? .now, kind: "level", entryID: entry.id,
            phrase: entry.text, translation: entry.translationText ?? "", fromLevel: from,
            toLevel: entry.learningLevel, origin: origin))
        context.insert(event)
        return event
    }

    static func event(entry: DictionaryEntry, date: Date?) throws -> UserActivityEvent? {
        guard let context = entry.modelContext, let date else { return nil }
        let id = entry.id
        let request = FetchDescriptor<UserActivityEvent>(predicate: #Predicate { $0.entryID == id && $0.date == date && !$0.reverted })
        return try context.fetch(request).first
    }
}
