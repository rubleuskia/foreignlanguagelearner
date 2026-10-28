import Foundation
import SwiftData

struct ActivityReportRequest: Hashable, Sendable {
    let language: String
    let period: ActivityPeriod
    let anchor: Date
    let calendar: Calendar

    init(language: String, period: ActivityPeriod, anchor: Date, calendar: Calendar) {
        self.language = SourceLanguage.canonical(language)
        self.period = period
        self.anchor = period.interval(containing: anchor, calendar: calendar).start
        self.calendar = calendar
    }
}

/// Only ready-to-display, bounded values cross back to the UI executor.
struct ActivityDashboardReport: Sendable {
    struct Bucket: Sendable, Identifiable {
        let start: Date
        let end: Date
        let value: Int
        let future: Bool
        var id: Date { start }
    }
    let language: String
    let updatedAt: Date
    let words: Int
    let phraseCount: Int
    let promotions: Int
    let learned: Int
    let seconds: Double
    let levelCounts: [Int: Int]
    let recentPhrases: [ActivityRecord]
    let previousWords: Int
    let buckets: [Bucket]
    let chartMaximum: Int
    let activeDays: Set<Date>
    let streak: Int

    static let empty = Self(language: "pl", updatedAt: .distantPast, words: 0, phraseCount: 0,
        promotions: 0, learned: 0, seconds: 0, levelCounts: [:], recentPhrases: [], previousWords: 0,
        buckets: [], chartMaximum: 5, activeDays: [], streak: 0)

    init(snapshot: ActivitySnapshot, request: ActivityReportRequest, updatedAt: Date) {
        let calendar = request.calendar
        let interval = request.period.interval(containing: request.anchor, calendar: calendar)
        let summary = snapshot.summary(language: request.language, interval: interval, now: updatedAt)
        language = request.language; self.updatedAt = updatedAt
        words = summary.words; phraseCount = summary.phrases.count; promotions = summary.promotions
        learned = summary.learned; seconds = summary.seconds
        levelCounts = Dictionary(grouping: summary.phrases, by: \.toLevel).mapValues(\.count)
        recentPhrases = Array(summary.phrases.prefix(10))
        let previousStart = calendar.date(byAdding: request.period.component, value: -1, to: interval.start)!
        let cutoff = max(interval.start, min(updatedAt, interval.end))
        let previousEnd = calendar.date(byAdding: request.period.component, value: -1, to: cutoff)!
        previousWords = snapshot.wordCount(language: language,
            interval: .init(start: previousStart, end: max(previousStart, previousEnd)), now: updatedAt)
        var buckets: [Bucket] = []
        var cursor = interval.start
        while cursor < interval.end {
            let end = min(calendar.date(byAdding: request.period == .day ? .hour : .day, value: 1, to: cursor)!, interval.end)
            let count = snapshot.wordCount(language: language, interval: .init(start: cursor, end: end), now: updatedAt)
            buckets.append(.init(start: cursor, end: end, value: count, future: cursor > updatedAt))
            cursor = end
        }
        self.buckets = buckets
        chartMaximum = max(5, buckets.map(\.value).max() ?? 0)
        activeDays = snapshot.activeDays(language: language, now: updatedAt, calendar: calendar)
        // Reuse the already computed day set rather than scanning history a second time.
        var day = calendar.startOfDay(for: updatedAt)
        if !activeDays.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var count = 0
        while activeDays.contains(day) {
            count += 1; day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        streak = count
    }

    private init(language: String, updatedAt: Date, words: Int, phraseCount: Int, promotions: Int,
                 learned: Int, seconds: Double, levelCounts: [Int: Int], recentPhrases: [ActivityRecord],
                 previousWords: Int, buckets: [Bucket], chartMaximum: Int, activeDays: Set<Date>, streak: Int) {
        self.language = language; self.updatedAt = updatedAt; self.words = words
        self.phraseCount = phraseCount; self.promotions = promotions; self.learned = learned
        self.seconds = seconds; self.levelCounts = levelCounts; self.recentPhrases = recentPhrases
        self.previousWords = previousWords; self.buckets = buckets; self.chartMaximum = chartMaximum
        self.activeDays = activeDays; self.streak = streak
    }
}

/// DB reads, decoding, indexing, report preparation and disk IO stay off the main actor.
/// Existing snapshots stay unchanged until an explicit pull-to-refresh succeeds.
actor ActivityStatisticsCache {
    typealias Loader = @Sendable (ModelContainer) async throws -> ActivitySnapshot
    static let shared = ActivityStatisticsCache(cacheURL: ProcessInfo.processInfo.arguments.contains("--uitesting") ? nil : defaultURL)
    static var defaultURL: URL {
        URL.cachesDirectory.appending(path: "Activity/statistics-v1.json")
    }

    private struct Stored: Codable, Sendable {
        let version: Int
        let updatedAt: Date
        let snapshot: ActivitySnapshot
    }
    private struct Flight {
        let id: UUID
        let force: Bool
        let task: Task<Stored, Error>
    }
    private let cacheURL: URL?
    private let loader: Loader
    private var stored: Stored?
    private var flight: Flight?
    private var reports: [ActivityReportRequest: ActivityDashboardReport] = [:]

    init(cacheURL: URL? = nil, loader: @escaping Loader = { try await ActivitySnapshot.load(container: $0) }) {
        self.cacheURL = cacheURL
        self.loader = loader
    }

    func report(container: ModelContainer, request: ActivityReportRequest, refresh: Bool = false) async throws -> ActivityDashboardReport {
        let loaded = try await data(container: container, force: refresh)
        let current = stored ?? loaded
        let language = resolvedLanguage(request.language, snapshot: current.snapshot)
        let key = ActivityReportRequest(language: language, period: request.period, anchor: request.anchor, calendar: request.calendar)
        if let report = reports[key] { return report }
        let report = ActivityDashboardReport(snapshot: current.snapshot, request: key, updatedAt: current.updatedAt)
        // Navigation can visit arbitrary dates, but the in-memory report cache stays bounded.
        if reports.count >= 96 { reports.removeAll(keepingCapacity: true) }
        reports[key] = report
        return report
    }

    func languages() -> [String] { stored?.snapshot.languageCodes ?? [] }

    private func resolvedLanguage(_ requested: String, snapshot: ActivitySnapshot) -> String {
        let codes = snapshot.languageCodes
        guard !codes.isEmpty, !codes.contains(requested) else { return requested }
        return SourceLanguage.supportedCodes.first(where: codes.contains) ?? codes.sorted().first ?? "pl"
    }

    private func data(container: ModelContainer, force: Bool) async throws -> Stored {
        if !force, let stored { return stored }
        if let flight {
            let value = try await finish(flight)
            // An explicit refresh must not be satisfied by an in-flight read of yesterday's disk cache.
            if force && !flight.force { return try await data(container: container, force: true) }
            return value
        }
        let cacheURL = self.cacheURL, loader = self.loader
        let task = Task.detached {
            if !force, let cacheURL, let data = try? Data(contentsOf: cacheURL),
               let cached = try? JSONDecoder().decode(Stored.self, from: data), cached.version == 1 {
                return cached
            }
            let snapshot = try await loader(container)
            try Task.checkCancellation()
            let value = Stored(version: 1, updatedAt: .now, snapshot: snapshot)
            if let cacheURL {
                // A derived-cache write failure must not discard otherwise valid statistics.
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(value) { try? data.write(to: cacheURL, options: .atomic) }
            }
            return value
        }
        let flight = Flight(id: UUID(), force: force, task: task)
        self.flight = flight
        return try await finish(flight)
    }

    private func finish(_ work: Flight) async throws -> Stored {
        do {
            let value = try await work.task.value
            if flight?.id == work.id {
                stored = value; reports.removeAll(keepingCapacity: true); flight = nil
            }
            return value
        } catch {
            if flight?.id == work.id { flight = nil }
            throw error
        }
    }
}
