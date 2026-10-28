#if DEBUG
import Foundation
import SwiftData

@MainActor enum ActivityUIFixture {
    static func seed(context: ModelContext) throws {
        guard ProcessInfo.processInfo.arguments.contains("--uitesting"),
              ProcessInfo.processInfo.arguments.contains("--activity-fixture"),
              try context.fetchCount(FetchDescriptor<UserActivityEvent>()) == 0 else { return }
        UserDefaults.standard.set("pl", forKey: SourceLanguage.activeKey)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let item = LearningItem(id: UUID(), title: "Lalka", mediaKind: "audio", mediaFilename: "",
                                transcriptFilename: "", duration: 0, segments: [])
        context.insert(item)
        for day in -12...0 {
            let date = day == 0 ? Date.now.addingTimeInterval(-1) : calendar.date(byAdding: .day, value: day, to: today)!.addingTimeInterval(8 * 3600)
            let forms = (0..<(day == 0 ? 18 : 25 + abs(day) * 3)).map { "word-\(day)-\($0)" }
            context.insert(ReadVocabularyBatch(language: "pl", formsData: try JSONEncoder().encode(forms), firstLearnedAt: date))
            context.insert(UserActivityEvent(.init(language: "pl", date: date, kind: "time", seconds: day == 0 ? 1920 : 3600)))
        }
        let phrases = [("Dzień dobry", "Добрый день", 3, 4), ("Nie ma za co", "Не за что", 2, 3), ("Mam na imię…", "Меня зовут…", 1, 2)]
        for (text, translation, from, to) in phrases {
            let entry = DictionaryEntry(text: text, item: item, segmentIndex: nil)
            entry.translationText = translation; entry.translationStatus = .ready; entry.learningLevel = to
            context.insert(entry)
            context.insert(UserActivityEvent(.init(language: "pl", date: .now.addingTimeInterval(-1), kind: "level",
                entryID: entry.id, phrase: text, translation: translation, fromLevel: from, toLevel: to, origin: "practice")))
        }
        context.insert(UserActivityEvent(.init(language: "en", date: today, kind: "time", seconds: 60)))
        try context.save()
    }
}
#endif
