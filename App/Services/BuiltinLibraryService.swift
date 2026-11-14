import Foundation
import CryptoKit
import SwiftData

struct LibraryBook: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let language: String
    let bytes: Int64
    let sha256: String
    var author: String? = nil
    var authorInfo: [String: String]? = nil
    var authorURL: URL? = nil
    var coverName: String? = nil
    var chapterCount: Int? = nil
    var contentFingerprint: String? = nil

    var metadata: LibraryBookMetadata {
        let fallback = LibraryBookMetadata.bundled[id] ?? .init()
        return .init(author: author ?? fallback.author, authorInfo: authorInfo ?? fallback.authorInfo,
                     authorURL: authorURL ?? fallback.authorURL, coverName: coverName ?? fallback.coverName,
                     chapterCount: chapterCount ?? fallback.chapterCount,
                     contentFingerprint: contentFingerprint ?? fallback.contentFingerprint)
    }
}

struct LibraryBookMetadata: Decodable, Sendable {
    var author: String? = nil
    var authorInfo: [String: String]? = nil
    var authorURL: URL? = nil
    var coverName: String? = nil
    var chapterCount: Int? = nil
    var contentFingerprint: String? = nil

    static let bundled: [String: Self] = {
        guard let url = Bundle.main.url(forResource: "BookLibraryMetadata", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: Self].self, from: data) else { return [:] }
        return value
    }()

    var biography: String? {
        authorInfo?[AppLanguage.current] ?? authorInfo?["en"]
    }
    var sourceURL: URL? {
        guard let authorURL, authorURL.scheme == "https", authorURL.host != nil else { return nil }
        return authorURL
    }
}

/// A content match upgrades old imports without relying on an editable title.
enum BuiltinLibraryIdentity {
    static func fingerprint(text: String, trackIDs: [String]) throws -> String {
        let value = try BookTextNormalization.normalize(text) + "\0" + trackIDs.joined(separator: "\0")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor static func fingerprint(_ item: LearningItem) throws -> String {
        let text = item.tracks.isEmpty ? item.segments.map(\.text).joined(separator: " ") :
            try String(contentsOf: MediaImportService.directory(for: item.id).appending(path: item.transcriptFilename), encoding: .utf8)
        return try fingerprint(text: text, trackIDs: item.tracks.map(\.id))
    }

    @MainActor static func existing(bookID: String, items: [LearningItem]) -> LearningItem? {
        items.first { $0.builtinLibraryID == bookID }
    }

    @MainActor static func existing(bookID: String, fingerprint: String, items: [LearningItem]) -> LearningItem? {
        existing(bookID: bookID, items: items) ?? items.first {
            $0.builtinLibraryID == nil && (try? Self.fingerprint($0)) == fingerprint
        }
    }

    /// Runs without suspension: another import cannot insert the same ID between check and save.
    @MainActor static func commit(_ candidate: LearningItem, bookID: String?, context: ModelContext) throws -> LearningItem {
        if let bookID {
            let items = try context.fetch(FetchDescriptor<LearningItem>())
            let fingerprint = try fingerprint(candidate)
            if let existing = existing(bookID: bookID, fingerprint: fingerprint, items: items) {
                let oldID = existing.builtinLibraryID
                existing.builtinLibraryID = bookID
                do { try context.save() }
                catch { existing.builtinLibraryID = oldID; throw error }
                return existing
            }
            candidate.builtinLibraryID = bookID
        }
        context.insert(candidate)
        do { try context.save() }
        catch { context.delete(candidate); throw error }
        return candidate
    }

    @MainActor static func reconcile(books: [LibraryBook], items: [LearningItem], context: ModelContext) async throws {
        let candidates = items.filter { $0.builtinLibraryID == nil && $0.hasText }.map { item in
            (item.id, item.tracks.isEmpty ? item.segments.map(\.text).joined(separator: " ") : nil,
             MediaImportService.directory(for: item.id).appending(path: item.transcriptFilename), item.tracks.map(\.id), item.resourceRevision)
        }
        let matches = await Task.detached(priority: .utility) {
            candidates.compactMap { id, inlineText, url, tracks, revision -> (UUID, String, String)? in
                guard !Task.isCancelled,
                      let text = inlineText ?? (try? String(contentsOf: url, encoding: .utf8)),
                      let fingerprint = try? fingerprint(text: text, trackIDs: tracks),
                      let book = books.first(where: { $0.metadata.contentFingerprint == fingerprint }) else { return nil }
                return (id, book.id, revision)
            }
        }.value
        try Task.checkCancellation()
        var changed: [LearningItem] = []
        for (id, bookID, revision) in matches {
            guard let item = items.first(where: { $0.id == id }), item.builtinLibraryID == nil,
                  item.resourceRevision == revision, item.modelContext != nil else { continue }
            item.builtinLibraryID = bookID; changed.append(item)
        }
        do { if !changed.isEmpty { try context.save() } }
        catch { for item in changed { item.builtinLibraryID = nil }; throw error }
    }
}

actor BuiltinLibraryService {
    static let baseURL: URL = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "BookLibraryAPIBaseURL") as? String,
           let url = URL(string: value), url.scheme == "https", url.host != nil,
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil { return url }
        return URL(string: "https://5h6q49tdi4.execute-api.eu-north-1.amazonaws.com")!
    }()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()
    private struct Catalog: Decodable { let books: [LibraryBook] }
    private struct Download: Decodable { let url: URL; let bytes: Int64; let sha256: String }

    private let authentication: OperatorSession
    private let client: any ContextAnalysisHTTPClient
    init(authentication: OperatorSession = .shared,
         client: any ContextAnalysisHTTPClient = URLSessionContextAnalysisHTTPClient(
            session: URLSession(configuration: .ephemeral))) {
        self.authentication = authentication; self.client = client
    }
    private func request<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        var lease = try await authentication.lease()
        func send(_ token: String) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: Self.baseURL.appending(path: path))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return try await client.data(for: request)
        }
        var (data, response) = try await send(lease.token)
        try await authentication.validate(lease)
        if response.statusCode == 401 {
            lease = try await authentication.lease(rejected: lease)
            (data, response) = try await send(lease.token) // GET only; refresh/retry at most once.
            try await authentication.validate(lease)
        }
        if response.statusCode == 401 { throw OperatorSessionError.signInRequired }
        if response.statusCode == 403 { throw OperatorSessionError.denied }
        guard response.statusCode == 200 else { throw failure(AppLanguage.format("Library unavailable (%d). Please try again.", response.statusCode)) }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func books() async throws -> [LibraryBook] {
        try await request("v1/library/books", as: Catalog.self).books
    }
    func download(_ book: LibraryBook) async throws -> URL {
        let info = try await request("v1/library/books/\(book.id)/download", as: Download.self)
        guard info.url.scheme == "https", info.url.host?.hasSuffix(".amazonaws.com") == true,
              info.bytes == book.bytes, info.sha256 == book.sha256 else {
            throw failure("The catalog changed. Refresh the book list.")
        }
        let (temporary, response) = try await session.download(from: info.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw failure("Could not download the book. Please try again.")
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk); count += Int64(chunk.count)
        }
        guard count == book.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == book.sha256 else {
            throw failure("The file is damaged. Download the book again.")
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID()).zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "BuiltinLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: AppLanguage.text(message)])
    }
}
