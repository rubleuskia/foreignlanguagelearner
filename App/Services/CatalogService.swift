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
    private struct CatalogPage: Decodable { let books: [CatalogBook]; let cursor: String? }
    func catalogBooks() async throws -> [CatalogBook] {
        var books: [CatalogBook] = [], cursor: String?
        repeat {
            let page: CatalogPage = try await request("v1/catalog/books", cursor: cursor)
            books += page.books; cursor = page.cursor
        } while cursor != nil
        return books
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
    private var stateURL: URL { CloudAlignmentFiles.root.appending(path: "catalog-imports.json") }

    init() {
        if let data = try? Data(contentsOf: stateURL), let stored = try? JSONDecoder().decode([String: Pending].self, from: data) { pending = stored }
    }
    func save() throws {
        try CloudAlignmentFiles.initialize()
        try JSONEncoder().encode(pending).write(to: stateURL, options: .atomic)
    }
    func reload() async {
        guard !loading else { return }
        loading = true; error = nil; legacyError = nil
        defer { loading = false }
        do { books = try await service.catalogBooks() }
        catch { self.error = error.localizedDescription }
        do {
            let ready = try await legacy.books().map(CatalogBook.ready)
            books.removeAll { $0.prepared != nil }
            books.insert(contentsOf: ready, at: 0)
        } catch { legacyError = error.localizedDescription }
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
