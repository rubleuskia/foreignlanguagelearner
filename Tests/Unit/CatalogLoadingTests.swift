import Foundation
import XCTest
@testable import ForeignLanguageLearner

final class CatalogLoadingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func book(_ id: String) -> CatalogBook {
        CatalogBook(id: id, title: id, language: "pl", author: "Author", genres: [], shelves: ["novels"],
            coverURL: nil, duration: "1:00", chapterCount: 1, parentID: nil, parentTitle: nil,
            sourceURL: URL(string: "https://wolnelektury.pl/katalog/lektura/\(id)/")!, sourceVersion: "v1")
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testCacheRoundTripAndIsolationFromDifferentAPI() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CatalogCache(directory: root)
        await cache.save(CatalogSnapshot(catalog: [book("saved")], catalogDate: date))
        let restored = await CatalogCache(directory: root).load()
        XCTAssertEqual(restored?.catalog.map(\.id), ["saved"])
        XCTAssertEqual(restored?.catalogDate, date)
        let different = await CatalogCache(directory: root, api: URL(string: "https://other.test")!).load()
        XCTAssertNil(different)
        try Data("broken".utf8).write(to: root.appending(path: "metadata.json"))
        let corrupt = await cache.load()
        XCTAssertNil(corrupt)
    }
    func testFreshnessRejectsExpiredAndFutureDates() {
        XCTAssertFalse(CatalogSnapshot.isFresh(nil, at: date))
        XCTAssertTrue(CatalogSnapshot.isFresh(date.addingTimeInterval(-3599), at: date))
        XCTAssertFalse(CatalogSnapshot.isFresh(date.addingTimeInterval(-3600), at: date))
        XCTAssertFalse(CatalogSnapshot.isFresh(date.addingTimeInterval(1), at: date))
    }
    @MainActor func testRelaunchShowsFreshCacheWithoutNetwork() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CatalogCache(directory: root)
        await cache.save(CatalogSnapshot(catalog: [book("saved")], catalogDate: date, readyDate: date))
        let browser = Browser(pages: [])
        let date = date
        let model = CatalogModel(browser: browser, cache: CatalogCache(directory: root), directory: root, now: { date })
        await model.reload(force: false)
        XCTAssertEqual(model.books.map(\.id), ["saved"])
        let counts = await browser.counts()
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0)
        XCTAssertNil(model.error)
    }
    @MainActor func testStaleCacheRemainsVisibleWhenOffline() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CatalogCache(directory: root)
        let old = date.addingTimeInterval(-7200), date = date
        await cache.save(CatalogSnapshot(catalog: [book("saved")], catalogDate: old, readyDate: old))
        let model = CatalogModel(browser: Browser(pages: [.failure(URLError(.notConnectedToInternet))], failReady: true),
            cache: cache, directory: root, now: { date })
        await model.reload(force: false)
        XCTAssertEqual(model.books.map(\.id), ["saved"])
        XCTAssertNotNil(model.error); XCTAssertNotNil(model.legacyError)
        let stored = await cache.load()
        XCTAssertEqual(stored?.catalogDate, old)
    }
    @MainActor func testFirstPagesAndReadyBooksAppearBeforeRemainingPagesFinish() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate(), cache = CatalogCache(directory: root)
        let browser = Browser(pages: [.success(.init(books: [book("first")], cursor: "next")),
            .success(.init(books: [book("second")], cursor: nil))], gate: gate,
            ready: [LibraryBook(id: "ready", title: "Ready", language: "pl", bytes: 1, sha256: "hash", author: "Author")])
        let model = CatalogModel(browser: browser, cache: cache, directory: root)
        let loading = Task { await model.reload() }
        await gate.waitUntilEntered()
        XCTAssertTrue(model.books.contains { $0.id == "first" })
        // Ready books must not wait behind the remaining catalog pages.
        await browser.waitUntilReadyReturned()
        for _ in 0..<20 where !model.books.contains(where: { $0.id == "ready" }) { await Task.yield() }
        XCTAssertTrue(model.books.contains { $0.id == "ready" })
        XCTAssertTrue(model.loading)
        let incomplete = await cache.load()
        XCTAssertNil(incomplete)
        await gate.release(); await loading.value
        XCTAssertEqual(model.books.map(\.id), ["ready", "first", "second"])
        let stored = await cache.load()
        XCTAssertEqual(stored?.catalog.map(\.id), ["first", "second"])
        let cursors = await browser.cursors
        XCTAssertEqual(cursors, [nil, "next"])
    }
    @MainActor func testForcedRefreshKeepsCompleteSnapshotUntilReplacementIsReady() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CatalogCache(directory: root), gate = Gate(), date = date
        await cache.save(CatalogSnapshot(catalog: [book("old")], catalogDate: date, readyDate: date))
        let browser = Browser(pages: [.success(.init(books: [book("new")], cursor: "next")),
            .success(.init(books: [], cursor: nil))], gate: gate)
        let model = CatalogModel(browser: browser, cache: cache, directory: root, now: { date })
        let loading = Task { await model.reload() }
        await gate.waitUntilEntered()
        XCTAssertEqual(model.books.map(\.id), ["old"])
        await gate.release(); await loading.value
        XCTAssertEqual(model.books.map(\.id), ["new"])
        let stored = await cache.load()
        XCTAssertEqual(stored?.catalog.map(\.id), ["new"])
    }
    @MainActor func testFailedPaginationDoesNotCachePartialCatalog() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CatalogCache(directory: root)
        let browser = Browser(pages: [.success(.init(books: [book("partial")], cursor: "next")),
            .failure(URLError(.networkConnectionLost))])
        let model = CatalogModel(browser: browser, cache: cache, directory: root)
        await model.reload()
        XCTAssertEqual(model.books.map(\.id), ["partial"])
        XCTAssertNotNil(model.error)
        let stored = await cache.load()
        XCTAssertNil(stored?.catalogDate)
        XCTAssertTrue(stored?.catalog.isEmpty == true)
    }
    @MainActor func testEmptySuccessfulRefreshClearsRemovedBooksAndCachesEmptyResult() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = CatalogCache(directory: root), date = date
        await cache.save(CatalogSnapshot(catalog: [book("removed")], catalogDate: date, readyDate: date))
        let browser = Browser(pages: [.success(.init(books: [], cursor: nil))])
        let model = CatalogModel(browser: browser, cache: cache, directory: root, now: { date })
        await model.reload()
        await model.reload(force: false)
        XCTAssertTrue(model.books.isEmpty)
        let counts = await browser.counts()
        XCTAssertEqual(counts.0, 1); XCTAssertEqual(counts.1, 1)
    }

    private actor Browser: CatalogBrowsing {
        var pages: [Result<CatalogPage, Error>]
        let gate: Gate?
        let ready: [LibraryBook]
        let failReady: Bool
        var cursors: [String?] = []
        var readyCalls = 0
        var readyWaiter: CheckedContinuation<Void, Never>?
        init(pages: [Result<CatalogPage, Error>], gate: Gate? = nil, ready: [LibraryBook] = [], failReady: Bool = false) {
            self.pages = pages; self.gate = gate; self.ready = ready; self.failReady = failReady
        }
        func page(cursor: String?) async throws -> CatalogPage {
            cursors.append(cursor)
            if cursors.count == 2 { await gate?.enter() }
            guard !pages.isEmpty else { throw URLError(.badServerResponse) }
            return try pages.removeFirst().get()
        }
        func readyBooks() async throws -> [LibraryBook] {
            readyCalls += 1; readyWaiter?.resume(); readyWaiter = nil
            if failReady { throw URLError(.notConnectedToInternet) }
            return ready
        }
        func waitUntilReadyReturned() async {
            if readyCalls == 0 { await withCheckedContinuation { readyWaiter = $0 } }
        }
        func counts() -> (Int, Int) { (cursors.count, readyCalls) }
    }
    private actor Gate {
        var continuation: CheckedContinuation<Void, Never>?
        var waiter: CheckedContinuation<Void, Never>?
        func enter() async {
            await withCheckedContinuation { continuation = $0; waiter?.resume(); waiter = nil }
        }
        func waitUntilEntered() async {
            if continuation == nil { await withCheckedContinuation { waiter = $0 } }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
}
