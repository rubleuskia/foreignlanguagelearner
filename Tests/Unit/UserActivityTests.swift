import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class UserActivityTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        value.firstWeekday = 2; value.minimumDaysInFirstWeek = 4
        return value
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    @MainActor private func container() throws -> ModelContainer {
        try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self,
            ReadVocabularyBatch.self, UserActivityEvent.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    @MainActor private func entry(_ context: ModelContext, level: Int = 2) -> DictionaryEntry {
        let book = LearningItem(id: UUID(), title: "Story", mediaKind: "audio", mediaFilename: "",
                                transcriptFilename: "", duration: 0, segments: [])
        let entry = DictionaryEntry(text: "dzień dobry", item: book, segmentIndex: nil)
        entry.translationText = "добрый день"; entry.translationStatus = .ready; entry.learningLevel = level
        context.insert(book); context.insert(entry)
        return entry
    }

    func testCountsUniquePhrasesHighestLevelAndExcludesUndoOtherLanguagesAndFuture() {
        let start = date("2026-10-26T00:00:00Z"), now = date("2026-10-28T12:00:00Z")
        let id = UUID()
        let first = ActivityRecord(language: "pl", date: start, kind: "level", entryID: id, fromLevel: 1, toLevel: 2)
        var second = first; second.id = UUID(); second.date = start.addingTimeInterval(10); second.fromLevel = 2; second.toLevel = 4
        var undone = first; undone.id = UUID(); undone.entryID = UUID(); undone.reverted = true
        var foreign = first; foreign.id = UUID(); foreign.language = "en"; foreign.entryID = UUID()
        var future = first; future.id = UUID(); future.date = now.addingTimeInterval(3600); future.entryID = UUID()
        let snapshot = ActivitySnapshot(words: [.init(language: "pl", date: start), .init(language: "en", date: start)],
            events: [first, second, undone, foreign, future, .init(language: "pl", date: start, kind: "time", seconds: 90)])
        let summary = snapshot.summary(language: "pl-PL", interval: ActivityPeriod.week.interval(containing: now, calendar: calendar), now: now)
        XCTAssertEqual(summary.words, 1); XCTAssertEqual(summary.phrases.count, 1)
        XCTAssertEqual(summary.phrases.first?.toLevel, 4); XCTAssertEqual(summary.promotions, 2)
        XCTAssertEqual(summary.learned, 1); XCTAssertEqual(summary.seconds, 90)
    }

    func testIntervalsRespectMondayMonthBoundaryAndDST() {
        let sunday = date("2026-10-25T12:00:00Z")
        XCTAssertEqual(ActivityPeriod.day.interval(containing: sunday, calendar: calendar).duration, 25 * 3600)
        let week = ActivityPeriod.week.interval(containing: sunday, calendar: calendar)
        XCTAssertEqual(calendar.component(.weekday, from: week.start), 2)
        XCTAssertFalse(week.contains(week.end.addingTimeInterval(1)))
        XCTAssertEqual(calendar.component(.day, from: ActivityPeriod.month.interval(containing: sunday, calendar: calendar).start), 1)
    }

    func testStreakAllowsTodayToBeUnfinishedButBreaksOnMissingDay() {
        let today = calendar.startOfDay(for: date("2026-10-28T12:00:00Z"))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let before = calendar.date(byAdding: .day, value: -2, to: today)!
        let snapshot = ActivitySnapshot(words: [.init(language: "pl", date: yesterday), .init(language: "pl", date: before)])
        XCTAssertEqual(snapshot.streak(language: "pl", now: today, calendar: calendar), 2)
        XCTAssertEqual(snapshot.streak(language: "en", now: today, calendar: calendar), 0)
        XCTAssertEqual(snapshot.streak(language: "pl", now: calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar), 0)
    }

    @MainActor func testAnswerUndoAndFailedSaveAreAtomic() throws {
        let db = try container(), context = db.mainContext
        let entry = entry(context)
        try context.save()
        var round = LearningRoundState(selection: .five, selectedIDs: [entry.id])
        let previousRound = round
        XCTAssertThrowsError(try LearningAnswerTransaction.apply(entry: entry, round: &round, expectedEntryID: entry.id,
            presentationID: round.currentPresentationID, right: true, save: { throw CocoaError(.fileWriteUnknown) }))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserActivityEvent>()), 0)
        XCTAssertEqual(entry.learningLevel, 2); XCTAssertEqual(round, previousRound)
        _ = try LearningAnswerTransaction.apply(entry: entry, round: &round, expectedEntryID: entry.id,
            presentationID: round.currentPresentationID, right: true, save: { try context.save() })
        let event = try XCTUnwrap(context.fetch(FetchDescriptor<UserActivityEvent>()).first)
        XCTAssertEqual(event.fromLevel, 2); XCTAssertEqual(event.toLevel, 3)
        let undo = LearningAnswerUndo(entryID: entry.id, previousLevel: 2, savedLevel: 3,
            previousRound: previousRound, answeredRound: round, expiresAt: .now.addingTimeInterval(30),
            savedLevelChangedAt: entry.levelChangedAt)
        XCTAssertThrowsError(try undo.restore(entry: entry, round: &round, save: { throw CocoaError(.fileWriteUnknown) }))
        XCTAssertFalse(event.reverted); XCTAssertEqual(entry.learningLevel, 3)
        XCTAssertTrue(try undo.restore(entry: entry, round: &round, save: { try context.save() }))
        XCTAssertTrue(event.reverted); XCTAssertEqual(entry.learningLevel, 2)
    }

    @MainActor func testNoLevelChangeUndoDoesNotRevertAnOlderEvent() throws {
        let db = try container(), context = db.mainContext
        let entry = entry(context, level: 1)
        entry.levelChangedAt = .now
        let prior = ActivityHistory.levelChange(entry: entry, from: 2, origin: "manual")!
        try context.save()
        var round = LearningRoundState(selection: .five, selectedIDs: [entry.id])
        let before = round
        _ = try LearningAnswerTransaction.apply(entry: entry, round: &round, expectedEntryID: entry.id,
            presentationID: round.currentPresentationID, right: false, save: { try context.save() })
        let undo = LearningAnswerUndo(entryID: entry.id, previousLevel: 1, savedLevel: 1,
            previousRound: before, answeredRound: round, expiresAt: .now.addingTimeInterval(30), savedLevelChangedAt: entry.levelChangedAt)
        XCTAssertTrue(try undo.restore(entry: entry, round: &round, save: { try context.save() }))
        XCTAssertFalse(prior.reverted)
    }

    @MainActor func testHistorySurvivesSourceDeletionAndSnapshotDeduplicatesReadingWords() async throws {
        let db = try container(), context = db.mainContext
        let entry = entry(context)
        entry.learningLevel = 3; entry.levelChangedAt = .now
        _ = ActivityHistory.levelChange(entry: entry, from: 2, origin: "manual")
        context.insert(ReadVocabularyWord(languageCode: "pl", normalizedForm: "kot", firstLearnedAt: date("2026-10-20T12:00:00Z")))
        context.insert(ReadVocabularyBatch(language: "pl", formsData: try JSONEncoder().encode(["kot", "pies"]), firstLearnedAt: date("2026-10-21T12:00:00Z")))
        context.delete(entry)
        try context.save()
        let snapshot = try await ActivitySnapshot.load(container: db)
        XCTAssertEqual(snapshot.words.count, 2); XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.words.filter { $0.date == date("2026-10-20T12:00:00Z") }.count, 1)
    }

    @MainActor func testTimeRecorderExcludesSuspensionPausesAndSplitsMidnight() throws {
        let db = try container(), recorder = ActivityTimeRecorder()
        let start = date("2026-10-27T22:59:59Z") // 23:59:59 Warsaw
        recorder.tick(eligible: true, now: start, uptime: 10, calendar: calendar)
        recorder.tick(eligible: true, now: start.addingTimeInterval(2), uptime: 12, calendar: calendar)
        recorder.tick(eligible: false, now: start.addingTimeInterval(3), uptime: 13, calendar: calendar)
        recorder.tick(eligible: true, now: start.addingTimeInterval(100), uptime: 110, calendar: calendar)
        recorder.tick(eligible: true, now: start.addingTimeInterval(200), uptime: 210, calendar: calendar)
        recorder.flush(language: "pl", context: db.mainContext, force: true)
        let events = try db.mainContext.fetch(FetchDescriptor<UserActivityEvent>())
        XCTAssertEqual(events.count, 2); XCTAssertEqual(events.reduce(0) { $0 + $1.seconds }, 2, accuracy: 0.01)
        XCTAssertEqual(Set(events.map { calendar.startOfDay(for: $0.date) }).count, 2)
    }

    @MainActor func testBackupMergesHistoryIdempotentlyAndPreservesLocalUndo() throws {
        let source = try container(), destination = try container()
        let record = ActivityRecord(language: "pl", date: .now, kind: "level", entryID: UUID(), fromLevel: 1, toLevel: 2)
        source.mainContext.insert(UserActivityEvent(record)); try source.mainContext.save()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let file = try LibraryBackupService.export(context: source.mainContext, defaults: defaults, cacheURL: nil)
        let document = try LibraryBackupService.decode(file.data)
        XCTAssertEqual(document.activity, [record])
        for _ in 0..<2 {
            let preview = try LibraryBackupService.preview(document, context: destination.mainContext)
            _ = try LibraryBackupService.restore(preview, context: destination.mainContext, defaults: defaults, cacheURL: nil)
        }
        let restored = try destination.mainContext.fetch(FetchDescriptor<UserActivityEvent>())
        XCTAssertEqual(restored.count, 1)
        restored[0].reverted = true; try destination.mainContext.save()
        let preview = try LibraryBackupService.preview(document, context: destination.mainContext)
        _ = try LibraryBackupService.restore(preview, context: destination.mainContext, defaults: defaults, cacheURL: nil)
        XCTAssertTrue(restored[0].reverted)
        var invalid = document; var bad = record; bad.kind = "unknown"; invalid.activity = [bad]
        XCTAssertThrowsError(try LibraryBackupService.decode(JSONEncoder().encode(invalid)))
        var legacy = document; legacy.activity = nil
        XCTAssertNil(try LibraryBackupService.decode(JSONEncoder().encode(legacy)).activity)
    }

    @MainActor func testBackupFailureDoesNotLeaveActivityBehind() throws {
        let source = try container(), destination = try container()
        source.mainContext.insert(UserActivityEvent(.init(language: "pl", date: .now, kind: "time", seconds: 90)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let file = try LibraryBackupService.export(context: source.mainContext, defaults: defaults, cacheURL: nil)
        let preview = try LibraryBackupService.preview(LibraryBackupService.decode(file.data), context: destination.mainContext)
        XCTAssertThrowsError(try LibraryBackupService.restore(preview, context: destination.mainContext,
            defaults: defaults, cacheURL: nil, save: { _ in throw CocoaError(.fileWriteUnknown) }))
        try destination.mainContext.save()
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<UserActivityEvent>()), 0)
    }
    @MainActor func testPreviewMarkKnownHistoryAndFailedSave() throws {
        let db = try container(), context = db.mainContext
        let entry = entry(context, level: 1)
        try context.save()
        var preview = LearningPreviewState(selection: .five, selectedIDs: [entry.id])
        XCTAssertThrowsError(try LearningPreviewTransaction.apply(entry: entry, preview: &preview,
            presentationID: preview.currentPresentationID, action: .markAsKnown, save: { throw CocoaError(.fileWriteUnknown) }))
        try context.save()
        XCTAssertEqual(entry.learningLevel, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<UserActivityEvent>()), 0)
        XCTAssertTrue(try LearningPreviewTransaction.apply(entry: entry, preview: &preview,
            presentationID: preview.currentPresentationID, action: .markAsKnown, save: { try context.save() }))
        let event = try XCTUnwrap(context.fetch(FetchDescriptor<UserActivityEvent>()).first)
        XCTAssertEqual(event.fromLevel, 1); XCTAssertEqual(event.toLevel, 4); XCTAssertEqual(event.origin, "preview")
    }

    @MainActor func testTimeFlushUpdatesOneSessionRowAndBackupTakesMaximum() throws {
        let db = try container(), recorder = ActivityTimeRecorder()
        let start = date("2026-10-28T10:00:00Z")
        recorder.tick(eligible: true, now: start, uptime: 10, calendar: calendar)
        recorder.tick(eligible: true, now: start.addingTimeInterval(2), uptime: 12, calendar: calendar)
        recorder.flush(language: "pl", context: db.mainContext, force: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = try LibraryBackupService.export(context: db.mainContext, defaults: defaults, cacheURL: nil)
        recorder.tick(eligible: true, now: start.addingTimeInterval(4), uptime: 14, calendar: calendar)
        recorder.flush(language: "pl", context: db.mainContext, force: true)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<UserActivityEvent>()), 1)
        let second = try LibraryBackupService.export(context: db.mainContext, defaults: defaults, cacheURL: nil)
        let target = try container()
        for file in [first, second, first] {
            let document = try LibraryBackupService.decode(file.data)
            _ = try LibraryBackupService.restore(LibraryBackupService.preview(document, context: target.mainContext),
                context: target.mainContext, defaults: defaults, cacheURL: nil)
        }
        let events = try target.mainContext.fetch(FetchDescriptor<UserActivityEvent>())
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].seconds, 4)
    }

    @MainActor func testAdditiveSchemaOpensExistingStoreWithoutInventingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "store.sqlite")
        let id: UUID
        do {
            let oldSchema = Schema([LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self])
            let old = try ModelContainer(for: oldSchema, configurations: ModelConfiguration(schema: oldSchema, url: url))
            let entry = entry(old.mainContext, level: 3)
            id = entry.id
            try old.mainContext.save()
        }
        let schema = Schema([LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self, UserActivityEvent.self])
        let upgraded = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        XCTAssertEqual(try upgraded.mainContext.fetch(FetchDescriptor<DictionaryEntry>()).first?.id, id)
        XCTAssertEqual(try upgraded.mainContext.fetch(FetchDescriptor<DictionaryEntry>()).first?.learningLevel, 3)
        XCTAssertEqual(try upgraded.mainContext.fetchCount(FetchDescriptor<UserActivityEvent>()), 0)
    }

}
