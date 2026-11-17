import Foundation

struct CatalogPage: Decodable, Sendable {
    let books: [CatalogBook]
    let cursor: String?
}

protocol CatalogBrowsing: Sendable {
    func page(cursor: String?) async throws -> CatalogPage
    func readyBooks() async throws -> [LibraryBook]
}

struct CatalogBrowser: CatalogBrowsing {
    let service: CloudAlignmentService
    let library: BuiltinLibraryService
    func page(cursor: String?) async throws -> CatalogPage { try await service.catalogPage(cursor: cursor) }
    func readyBooks() async throws -> [LibraryBook] { try await library.books() }
}

struct CatalogSnapshot: Codable, Sendable {
    var catalog: [CatalogBook] = []
    var ready: [LibraryBook] = []
    var catalogDate: Date?
    var readyDate: Date?

    static func isFresh(_ date: Date?, at now: Date) -> Bool {
        guard let date else { return false }
        return (0..<3600).contains(now.timeIntervalSince(date))
    }
}

/// Only completed metadata responses are persisted; imports and signed URLs stay separate.
actor CatalogCache {
    private struct Stored: Codable {
        let version: Int
        let api: URL
        let snapshot: CatalogSnapshot
    }
    private let file: URL
    private let api: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "BookCatalog", directoryHint: .isDirectory), api: URL = BuiltinLibraryService.baseURL) {
        file = directory.appending(path: "metadata.json"); self.api = api
    }

    func load() -> CatalogSnapshot? {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == 1, stored.api == api else { return nil }
        return stored.snapshot
    }

    func save(_ snapshot: CatalogSnapshot) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Stored(version: 1, api: api, snapshot: snapshot)).write(to: file, options: .atomic)
        } catch {
            // Cache eviction or a full disk must not turn a successful metadata fetch into a failure.
        }
    }
}
