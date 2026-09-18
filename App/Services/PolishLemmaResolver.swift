import Compression
import Foundation
import SQLite3

protocol PolishLemmaResolving: Sendable {
    func lemmas(for word: String) async throws -> [String]
}

actor BundledPolishLemmaResolver: PolishLemmaResolving {
    private static let databaseFilename = "PolishLemmas-20260823.sqlite3"

    private let compressedResourceURL: URL?
    private let destinationDirectory: URL
    private var installedDatabaseURL: URL?

    init(bundle: Bundle = .main, destinationDirectory: URL? = nil) {
        compressedResourceURL = bundle.url(
            forResource: "PolishLemmas",
            withExtension: "sqlite3.zlib",
            subdirectory: "PolishMorphology"
        ) ?? bundle.url(forResource: "PolishLemmas", withExtension: "sqlite3.zlib")
        self.destinationDirectory = destinationDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "PolishMorphology", directoryHint: .isDirectory)
    }

    init(databaseURL: URL) {
        compressedResourceURL = nil
        destinationDirectory = databaseURL.deletingLastPathComponent()
        installedDatabaseURL = databaseURL
    }

    func lemmas(for word: String) async throws -> [String] {
        let normalized = Self.normalized(word)
        guard !normalized.isEmpty else { return [] }
        let databaseURL = try installedDatabaseURL ?? installDatabase()
        installedDatabaseURL = databaseURL
        return try Self.query(normalized, databaseURL: databaseURL)
    }

    private func installDatabase() throws -> URL {
        let manager = FileManager.default
        let destination = destinationDirectory.appending(path: Self.databaseFilename)
        if manager.fileExists(atPath: destination.path) { return destination }
        guard let compressedResourceURL else { throw PolishLemmaResolverError.resourceMissing }

        try manager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let temporary = destinationDirectory.appending(path: "\(Self.databaseFilename).installing")
        if manager.fileExists(atPath: temporary.path) { try manager.removeItem(at: temporary) }
        guard manager.createFile(atPath: temporary.path, contents: nil) else {
            throw PolishLemmaResolverError.installationFailed
        }

        do {
            try Self.decompress(compressedResourceURL, to: temporary)
            try manager.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    private static func decompress(_ sourceURL: URL, to destinationURL: URL) throws {
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? source.close()
            try? destination.close()
        }

        let filter = try InputFilter<Data>(.decompress, using: .zlib) { requestedLength in
            try source.read(upToCount: requestedLength)
        }
        while let data = try filter.readData(ofLength: 64 * 1024), !data.isEmpty {
            try destination.write(contentsOf: data)
        }
        try destination.synchronize()
    }

    private static func query(_ form: String, databaseURL: URL) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            throw PolishLemmaResolverError.databaseUnavailable
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = "SELECT title FROM lemma_lookup WHERE form = ? ORDER BY title"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PolishLemmaResolverError.databaseUnavailable
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, form, -1, transient) == SQLITE_OK else {
            throw PolishLemmaResolverError.databaseUnavailable
        }

        var results: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let value = sqlite3_column_text(statement, 0) {
                    results.append(String(cString: value))
                }
            case SQLITE_DONE:
                return results
            default:
                throw PolishLemmaResolverError.databaseUnavailable
            }
        }
    }

    private static func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "pl_PL"))
    }
}

enum PolishLemmaResolverError: LocalizedError {
    case resourceMissing
    case installationFailed
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .resourceMissing: "The bundled Polish morphology database is missing."
        case .installationFailed: "The Polish morphology database could not be installed."
        case .databaseUnavailable: "The Polish morphology database could not be read."
        }
    }
}
