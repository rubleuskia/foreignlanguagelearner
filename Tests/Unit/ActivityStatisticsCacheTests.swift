import SwiftData
import XCTest
@testable import ForeignLanguageLearner

private actor ActivityCacheProbe {
    var value = ActivitySnapshot()
    var reads = 0
    var shouldFail = false
    var delay = false
    func set(_ snapshot: ActivitySnapshot, fail: Bool = false, delay: Bool = false) {
        value = snapshot; shouldFail = fail; self.delay = delay
    }
    func load() async throws -> ActivitySnapshot {
        reads += 1
        if delay { try await Task.sleep(for: .milliseconds(80)) }
        if shouldFail { throw CocoaError(.fileReadUnknown) }
        return value
    }
}

final class ActivityStatisticsCacheTests: XCTestCase {
    @MainActor private func container() throws -> ModelContainer {
        try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self,
            ReadVocabularyBatch.self, UserActivityEvent.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private var request: ActivityReportRequest {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        return .init(language: "pl", period: .day, anchor: .now, calendar: calendar)
    }
    private func snapshot(_ words: Int) -> ActivitySnapshot {
        .init(words: [.init(language: "pl", date: .now.addingTimeInterval(-1), count: words)], languageCodes: ["pl"])
    }

    @MainActor func testDataStaysFrozenAcrossNavigationUntilExplicitRefresh() async throws {
        let db = try container(), probe = ActivityCacheProbe()
        await probe.set(snapshot(18))
        let cache = ActivityStatisticsCache(loader: { _ in try await probe.load() })
        let first = try await cache.report(container: db, request: request)
        XCTAssertEqual(first.words, 18)
        await probe.set(snapshot(99))
        let same = try await cache.report(container: db, request: request)
        var month = request
        month = .init(language: month.language, period: .month, anchor: month.anchor, calendar: month.calendar)
        let otherPeriod = try await cache.report(container: db, request: month)
        XCTAssertEqual(same.words, 18); XCTAssertEqual(otherPeriod.words, 18)
        let before = await probe.reads
        XCTAssertEqual(before, 1)
        let refreshed = try await cache.report(container: db, request: request, refresh: true)
        XCTAssertEqual(refreshed.words, 99)
        let monthRefreshed = try await cache.report(container: db, request: month)
        XCTAssertEqual(monthRefreshed.words, 99)
        let after = await probe.reads
        XCTAssertEqual(after, 2)
    }

    @MainActor func testDiskCacheSurvivesNewCacheInstanceWithoutReadingDatabase() async throws {
        let db = try container(), probe = ActivityCacheProbe()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "activity.json")
        await probe.set(snapshot(24))
        let first = ActivityStatisticsCache(cacheURL: url, loader: { _ in try await probe.load() })
        _ = try await first.report(container: db, request: request)
        await probe.set(snapshot(80), fail: true)
        let restarted = ActivityStatisticsCache(cacheURL: url, loader: { _ in try await probe.load() })
        let cached = try await restarted.report(container: db, request: request)
        XCTAssertEqual(cached.words, 24)
        let reads = await probe.reads
        XCTAssertEqual(reads, 1)
        do { _ = try await restarted.report(container: db, request: request, refresh: true); XCTFail("Expected read failure") }
        catch { }
        let retained = try await restarted.report(container: db, request: request)
        XCTAssertEqual(retained.words, 24)
        await probe.set(snapshot(80))
        let fresh = try await restarted.report(container: db, request: request, refresh: true)
        XCTAssertEqual(fresh.words, 80)
    }

    @MainActor func testCorruptCacheRebuildsOnceAndConcurrentRequestsCoalesce() async throws {
        let db = try container(), probe = ActivityCacheProbe()
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupt".utf8).write(to: url)
        await probe.set(snapshot(12), delay: true)
        let cache = ActivityStatisticsCache(cacheURL: url, loader: { _ in try await probe.load() })
        let selection = request
        async let one = cache.report(container: db, request: selection)
        async let two = cache.report(container: db, request: selection)
        let initial = try await [one, two]
        XCTAssertEqual(initial.map(\.words), [12, 12])
        let firstReads = await probe.reads
        XCTAssertEqual(firstReads, 1)
        async let refreshOne = cache.report(container: db, request: selection, refresh: true)
        async let refreshTwo = cache.report(container: db, request: selection, refresh: true)
        _ = try await [refreshOne, refreshTwo]
        let secondReads = await probe.reads
        XCTAssertEqual(secondReads, 2)
    }

    @MainActor func testExplicitRefreshDuringDiskLoadStillLoadsFreshData() async throws {
        let db = try container(), probe = ActivityCacheProbe()
        await probe.set(snapshot(8), delay: true)
        let cache = ActivityStatisticsCache(loader: { _ in try await probe.load() })
        let selection = request
        async let initial = cache.report(container: db, request: selection)
        try await Task.sleep(for: .milliseconds(10))
        async let explicit = cache.report(container: db, request: selection, refresh: true)
        _ = try await [initial, explicit]
        let reads = await probe.reads
        XCTAssertEqual(reads, 2)
    }

    @MainActor func testPreparedReportHasBoundedPhrasesAndCorrectCounts() async throws {
        let db = try container()
        let selection = request, date = Date.now.addingTimeInterval(-1)
        let events = (0..<100).map { index in
            ActivityRecord(language: "pl", date: date, kind: "level", entryID: UUID(), phrase: "Phrase \(index)", fromLevel: 1, toLevel: index % 2 == 0 ? 2 : 4)
        }
        let source = ActivitySnapshot(words: [.init(language: "pl", date: date, count: 300)], events: events, languageCodes: ["pl", "en"])
        let cache = ActivityStatisticsCache(loader: { _ in source })
        let report = try await cache.report(container: db, request: selection)
        XCTAssertEqual(report.words, 300); XCTAssertEqual(report.phraseCount, 100)
        XCTAssertEqual(report.recentPhrases.count, 10); XCTAssertEqual(report.promotions, 100)
        XCTAssertEqual(report.levelCounts[2], 50); XCTAssertEqual(report.learned, 50)
        XCTAssertEqual(report.buckets.reduce(0) { $0 + $1.value }, 300)
        XCTAssertTrue((23...25).contains(report.buckets.count))
        XCTAssertEqual(report.activeDays.count, 1); XCTAssertEqual(report.streak, 1)
        let foreign = ActivityReportRequest(language: "en", period: selection.period, anchor: selection.anchor, calendar: selection.calendar)
        let english = try await cache.report(container: db, request: foreign)
        XCTAssertEqual(english.words, 0); XCTAssertEqual(english.phraseCount, 0)
    }

    @MainActor func testExplicitRefreshReadsNewPersistedActivityWithProductionLoader() async throws {
        let db = try container(), cache = ActivityStatisticsCache()
        let selection = request
        let first = try await cache.report(container: db, request: selection)
        XCTAssertEqual(first.phraseCount, 0)
        db.mainContext.insert(UserActivityEvent(.init(language: "pl", date: .now, kind: "level", entryID: UUID(), fromLevel: 1, toLevel: 2)))
        try db.mainContext.save()
        let same = try await cache.report(container: db, request: selection)
        XCTAssertEqual(same.phraseCount, 0)
        let fresh = try await cache.report(container: db, request: selection, refresh: true)
        XCTAssertEqual(fresh.phraseCount, 1)
    }

    @MainActor func testWarmLargeHistoryReportsUsePreparedCache() async throws {
        let db = try container(), selection = request
        let date = Date.now.addingTimeInterval(-1)
        let source = ActivitySnapshot(words: [.init(language: "pl", date: date, count: 500_000)],
            events: (0..<30_000).map { _ in
                .init(language: "pl", date: date, kind: "level", entryID: UUID(), fromLevel: 1, toLevel: 2)
            }, languageCodes: ["pl"])
        let cache = ActivityStatisticsCache(loader: { _ in source })
        let initial = try await cache.report(container: db, request: selection)
        XCTAssertEqual(initial.phraseCount, 30_000)
        let start = ContinuousClock.now
        for _ in 0..<100 {
            let cached = try await cache.report(container: db, request: selection)
            XCTAssertEqual(cached.phraseCount, 30_000)
        }
        let elapsed = start.duration(to: .now)
        // A generous budget still catches accidentally re-aggregating 30k events on each UI read.
        XCTAssertLessThan(elapsed, .seconds(1))
    }
}
