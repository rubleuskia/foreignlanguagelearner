import Foundation
import Observation
import SwiftData

struct CatalogBook: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let title: String
    let language: String
    let author: String
    let genres: [String]
    let shelves: [String]
    let coverURL: URL?
    let duration: String
    let chapterCount: Int
    let parentID: String?
    let parentTitle: String?
    let sourceURL: URL
    let sourceVersion: String
    var excerpt: String? = nil
    var chapters: [String]? = nil
    var prepared: LibraryBook? = nil

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.sourceVersion == rhs.sourceVersion }
    func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(sourceVersion) }
    var libraryIdentity: LibraryBook {
        prepared ?? LibraryBook(id: id, title: title, language: language, bytes: 0, sha256: "", author: author)
    }
    static func ready(_ book: LibraryBook) -> Self {
        .init(id: book.id, title: book.title, language: book.language, author: book.metadata.author ?? "",
              genres: [], shelves: ["ready"], coverURL: nil, duration: "", chapterCount: book.metadata.chapterCount ?? 0,
              parentID: nil, parentTitle: nil, sourceURL: URL(string: "https://wolnelektury.pl/")!,
              sourceVersion: book.sha256, prepared: book)
    }
}

extension CloudAlignmentService {
    func catalogPage(cursor: String?) async throws -> CatalogPage {
        try await request("v1/catalog/books", cursor: cursor)
    }
    func catalogDetail(_ id: String) async throws -> CatalogBook { try await request("v1/catalog/books/\(id)") }
    func importCatalogBook(_ id: String) async throws -> CloudAlignmentJob {
        try await request("v1/catalog/books/\(id)/import", method: "POST")
    }
}

@MainActor @Observable final class CatalogModel {
    static let shared = CatalogModel()
    struct Pending: Codable { let book: CatalogBook; var job: CloudAlignmentJob }
    var books: [CatalogBook] = []
    var pending: [String: Pending] = [:]
    var loading = false
    var downloading: Set<String> = []
    var error: String?
    var legacyError: String?
    private var automatic: Set<String> = []
    private var polling = false
    private let service = CloudAlignmentService()
    private let legacy = BuiltinLibraryService()
    private let browser: any CatalogBrowsing
    private let cache: CatalogCache
    private let directory: URL
    private let now: @Sendable () -> Date
    private var snapshot = CatalogSnapshot()
    private var restored = false
    private var stateURL: URL { directory.appending(path: "catalog-imports.json") }

    init(browser: (any CatalogBrowsing)? = nil, cache: CatalogCache = CatalogCache(),
         directory: URL = CloudAlignmentFiles.root, now: @escaping @Sendable () -> Date = { Date() }) {
        self.browser = browser ?? CatalogBrowser(service: service, library: legacy)
        self.cache = cache; self.directory = directory; self.now = now
        #if DEBUG
        if CatalogNavigationUIFixture.enabled {
            snapshot = CatalogNavigationUIFixture.snapshot
            books = snapshot.catalog; pending = CatalogNavigationUIFixture.requests
            restored = true
            return
        }
        #endif
        if let data = try? Data(contentsOf: stateURL), let stored = try? JSONDecoder().decode([String: Pending].self, from: data) { pending = stored }
    }
    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(pending).write(to: stateURL, options: .atomic)
    }
    func reload(force: Bool = true) async {
        guard !loading else { return }
        loading = true; error = nil; legacyError = nil
        defer { loading = false }
        if !restored {
            if let saved = await cache.load() { snapshot = saved; display() }
            restored = true
        }
        guard !Task.isCancelled else { return }
        let date = now()
        async let catalogChanged = refreshCatalog(force: force, at: date)
        async let readyChanged = refreshReady(force: force, at: date)
        let changed = await (catalogChanged, readyChanged)
        if changed.0 || changed.1 { await cache.save(snapshot) }
    }
    private func display(catalog: [CatalogBook]? = nil) {
        books = snapshot.ready.map(CatalogBook.ready) + (catalog ?? snapshot.catalog)
    }
    private func refreshCatalog(force: Bool, at date: Date) async -> Bool {
        guard force || !CatalogSnapshot.isFresh(snapshot.catalogDate, at: date) else { return false }
        var collected: [CatalogBook] = [], cursor: String?, seen: Set<String> = []
        let showPages = snapshot.catalogDate == nil
        do {
            repeat {
                try Task.checkCancellation()
                let page = try await browser.page(cursor: cursor)
                try Task.checkCancellation()
                collected += page.books
                if showPages { display(catalog: collected) }
                cursor = page.cursor
                if let cursor, !seen.insert(cursor).inserted { throw CloudAlignmentFiles.invalid("Invalid catalog cursor.") }
            } while cursor != nil
            snapshot.catalog = collected; snapshot.catalogDate = date
            display()
            return true
        } catch is CancellationError { return false }
        catch { if !Task.isCancelled { self.error = error.localizedDescription }; return false }
    }
    private func refreshReady(force: Bool, at date: Date) async -> Bool {
        guard force || !CatalogSnapshot.isFresh(snapshot.readyDate, at: date) else { return false }
        do {
            let ready = try await browser.readyBooks()
            try Task.checkCancellation()
            snapshot.ready = ready; snapshot.readyDate = date
            // Preserve already visible first-load pages while the catalog is still arriving.
            books = ready.map(CatalogBook.ready) + books.filter { $0.prepared == nil }
            return true
        } catch is CancellationError { return false }
        catch { if !Task.isCancelled { legacyError = error.localizedDescription }; return false }
    }
    func start(_ book: CatalogBook) async {
        guard !downloading.contains(book.id) else { return }
        error = nil
        do {
            let job = try await service.importCatalogBook(book.id)
            pending[book.id] = .init(book: book, job: job)
            try save()
            automatic.insert(book.id)
        } catch { self.error = error.localizedDescription }
    }
    func suspendAutomaticDownloads() { automatic.removeAll() }
    func poll(context: ModelContext) async {
        #if DEBUG
        if CatalogNavigationUIFixture.enabled {
            CatalogNavigationUIFixture.update(&pending)
            return
        }
        #endif
        guard !polling else { return }
        polling = true
        defer { polling = false }
        for id in Array(pending.keys) {
            guard var value = pending[id] else { continue }
            do {
                if !value.job.terminal { value.job = try await service.status(value.job.id); pending[id] = value; try save() }
                if value.job.succeeded, automatic.contains(id) { await download(value.book, context: context) }
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
    }
    func download(_ book: CatalogBook, context: ModelContext) async {
        guard !downloading.contains(book.id) else { return }
        downloading.insert(book.id); error = nil
        defer { downloading.remove(book.id); automatic.remove(book.id) }
        do {
            let url: URL
            if let prepared = book.prepared { url = try await legacy.download(prepared) }
            else {
                guard let job = pending[book.id]?.job, job.succeeded else { return }
                url = try await service.download(job.id)
            }
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try await CatalogImporter.commit(url, book: book, context: context)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

enum CatalogImporter {
    @MainActor static func commit(_ archive: URL, book: CatalogBook, context: ModelContext) async throws -> LearningItem {
        let importer = BookImportService()
        let preview = try await importer.previewArchive(archive)
        var staged: BookImportService.Prepared?
        do {
            let prepared = try await importer.prepare(preview, title: book.title, sourceLanguage: book.language,
                orderedTracks: preview.tracks, transcriptPath: preview.selectedTranscript, externalTranscript: nil)
            _ = try await importer.vocabularyPreview(prepared)
            try Task.checkCancellation()
            try await importer.movePreparedToLibrary(prepared); staged = prepared
            try Task.checkCancellation()
            let item = LearningItem(id: prepared.itemID, title: prepared.title, mediaKind: "audio", mediaFilename: "",
                transcriptFilename: prepared.transcriptFilename, duration: prepared.duration, segments: [],
                sourceLanguageCode: prepared.sourceLanguage, tracks: prepared.tracks, lastTrackID: prepared.tracks.first?.id)
            item.coverFilename = prepared.coverFilename ?? ""
            item.bundledCoverName = book.prepared?.metadata.coverName ?? "cover-books"
            item.readingVocabularyMigrationVersion = 1
            let result = try BuiltinLibraryIdentity.commit(item, bookID: book.id, context: context)
            if result.id == item.id { await importer.complete(prepared) }
            else { await importer.rollback(prepared) }
            await importer.cancel(preview)
            return result
        } catch {
            if let staged { await importer.rollback(staged) }
            await importer.cancel(preview)
            throw error
        }
    }
}
