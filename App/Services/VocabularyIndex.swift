import CryptoKit
import Foundation
import SQLite3

struct BookVocabularySummary: Equatable, Sendable {
    let total: Int
    let new: Int
}

/// Disposable projection. SwiftData owns knowledge; startup reconciles it before publishing counts.
/// All SQL, source I/O and tokenization are confined to this actor, never the UI executor.
actor VocabularyIndex {
    nonisolated static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "VocabularyIndex/index-v1.sqlite")
    }
    private let url: URL?
    private var database: VocabularyDatabase?
    private(set) var tokenizedSources = 0
    private(set) var visitedPostings = 0

    init(url: URL? = nil) { self.url = url }

    private func db() throws -> VocabularyDatabase {
        if let database { return database }
        let value = try VocabularyDatabase(url: url)
        database = value
        return value
    }

    func reset() throws {
        database = nil
        guard let url else { return }
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func reconcile(_ knowledge: [String: Set<String>]) throws -> [UUID: BookVocabularySummary] {
        let db = try db()
        try db.transaction {
            // An exact snapshot also handles test resets or recovery from a replaced primary store.
            try db.run("CREATE TEMP TABLE IF NOT EXISTS snapshot(word_id INTEGER PRIMARY KEY)")
            try db.run("DELETE FROM snapshot")
            for (language, forms) in knowledge {
                for form in forms {
                    try Task.checkCancellation()
                    try db.run("INSERT OR IGNORE INTO snapshot VALUES (?)", [.int(try db.word(language, form))])
                }
            }
            try db.run("CREATE TEMP TABLE IF NOT EXISTS delta(word_id INTEGER PRIMARY KEY)")
            try db.run("DELETE FROM delta")
            try db.run("INSERT INTO delta SELECT word_id FROM known EXCEPT SELECT word_id FROM snapshot")
            _ = try adjustCounts(db, direction: 1)
            try db.run("DELETE FROM known WHERE word_id IN (SELECT word_id FROM delta)")
            try db.run("DELETE FROM delta")
            try db.run("INSERT INTO delta SELECT word_id FROM snapshot EXCEPT SELECT word_id FROM known")
            _ = try adjustCounts(db, direction: -1)
            try db.run("INSERT OR IGNORE INTO known SELECT word_id FROM delta")
        }
        return try summaries()
    }

    func learn(_ forms: Set<String>, language: String) throws -> [UUID: BookVocabularySummary] {
        let db = try db()
        var affected: [String] = []
        try db.transaction {
            try db.run("CREATE TEMP TABLE IF NOT EXISTS delta(word_id INTEGER PRIMARY KEY)")
            try db.run("DELETE FROM delta")
            for form in forms {
                try Task.checkCancellation()
                let id = try db.word(language, form)
                try db.run("INSERT OR IGNORE INTO delta SELECT ? WHERE NOT EXISTS (SELECT 1 FROM known WHERE word_id=?)", [.int(id), .int(id)])
            }
            affected = try adjustCounts(db, direction: -1)
            try db.run("INSERT OR IGNORE INTO known SELECT word_id FROM delta")
        }
        var result: [UUID: BookVocabularySummary] = [:]
        for id in affected {
            if let uuid = UUID(uuidString: id), let summary = try summary(id) { result[uuid] = summary }
        }
        return result
    }

    private func adjustCounts(_ db: VocabularyDatabase, direction: Int) throws -> [String] {
        let counts = try db.rows("SELECT bw.book_id, COUNT(*) FROM delta d CROSS JOIN book_word bw INDEXED BY book_word_by_word ON bw.word_id=d.word_id GROUP BY bw.book_id")
        for row in counts {
            let count = Int(row[1])!
            visitedPostings += count
            try db.run("UPDATE book SET new_count=new_count+? WHERE id=?", [.int(Int64(direction * count)), .text(row[0])])
        }
        return counts.map { $0[0] }
    }

    func analyze(_ sources: [ReadingTextSource], language: String) throws -> (words: Set<String>, fingerprint: String) {
        let db = try db()
        var words = Set<String>()
        var fingerprints: [String] = []
        for source in sources {
            try Task.checkCancellation()
            let key = try source.cacheKey()
            fingerprints.append(key)
            if try db.rows("SELECT id FROM source WHERE id=?", [.text(key)]).isEmpty {
                let text = try source.load()
                let forms = try VocabularyTokenizer.forms(in: text)
                // A file changed while being read: never cache it under its previous revision.
                guard try source.cacheKey() == key else { throw ReadingVocabularyError.changed }
                try db.transaction {
                    try db.run("INSERT INTO source(id) VALUES (?)", [.text(key)])
                    for form in forms {
                        try Task.checkCancellation()
                        try db.run("INSERT INTO source_form(source_id,form) VALUES (?,?)", [.text(key), .text(form)])
                    }
                }
                tokenizedSources += 1
            }
            for row in try db.rows("SELECT form FROM source_form WHERE source_id=?", [.text(key)]) { words.insert(row[0]) }
        }
        return (words, Self.digest(fingerprints.joined(separator: ":")))
    }

    func indexBook(id: UUID, language: String, sources: [ReadingTextSource]) throws -> BookVocabularySummary {
        let db = try db()
        let keys = try sources.map { try $0.cacheKey() }
        let fingerprint = Self.digest(keys.joined(separator: ":"))
        let previous = try db.rows("SELECT revision,language FROM book WHERE id=?", [.text(id.uuidString)]).first
        if previous == [fingerprint, language], let summary = try summary(id.uuidString) { return summary }
        let result = try analyze(sources, language: language)
        try Task.checkCancellation()
        try db.transaction {
            try db.run("DELETE FROM book_word WHERE book_id=?", [.text(id.uuidString)])
            try db.run("DELETE FROM book_source WHERE book_id=?", [.text(id.uuidString)])
            try db.run("INSERT OR REPLACE INTO book(id,language,revision,total_count,new_count) VALUES (?,?,?,0,0)", [.text(id.uuidString), .text(language), .text(result.fingerprint)])
            for key in keys { try db.run("INSERT OR IGNORE INTO book_source VALUES (?,?)", [.text(id.uuidString), .text(key)]) }
            for form in result.words {
                try Task.checkCancellation()
                let word = try db.word(language, form)
                try db.run("INSERT INTO book_word VALUES (?,?)", [.text(id.uuidString), .int(word)])
            }
            try db.run("UPDATE book SET total_count=?,new_count=(SELECT COUNT(*) FROM book_word bw LEFT JOIN known k ON k.word_id=bw.word_id WHERE bw.book_id=book.id AND k.word_id IS NULL) WHERE id=?", [.int(Int64(result.words.count)), .text(id.uuidString)])
        }
        return try summary(id.uuidString)!
    }

    func retainBooks(_ ids: Set<UUID>) throws {
        let db = try db()
        try db.transaction {
            for row in try db.rows("SELECT id FROM book") where !ids.contains(UUID(uuidString: row[0])!) {
                try db.run("DELETE FROM book_word WHERE book_id=?", [.text(row[0])])
                try db.run("DELETE FROM book_source WHERE book_id=?", [.text(row[0])])
                try db.run("DELETE FROM book WHERE id=?", [.text(row[0])])
            }
            try db.run("DELETE FROM source_form WHERE source_id NOT IN (SELECT source_id FROM book_source)")
            try db.run("DELETE FROM source WHERE id NOT IN (SELECT source_id FROM book_source)")
            try db.run("DELETE FROM word WHERE id NOT IN (SELECT word_id FROM known) AND id NOT IN (SELECT word_id FROM book_word)")
        }
    }

    func summaries() throws -> [UUID: BookVocabularySummary] {
        var result: [UUID: BookVocabularySummary] = [:]
        for row in try db().rows("SELECT id,total_count,new_count FROM book") {
            if let id = UUID(uuidString: row[0]) { result[id] = .init(total: Int(row[1])!, new: Int(row[2])!) }
        }
        return result
    }

    private func summary(_ id: String) throws -> BookVocabularySummary? {
        guard let row = try db().rows("SELECT total_count,new_count FROM book WHERE id=?", [.text(id)]).first else { return nil }
        return .init(total: Int(row[0])!, new: Int(row[1])!)
    }

    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension ReadingTextSource {
    /// Imported files are app-owned and immutable. Changes in identity/size/mtime/ctime invalidate
    /// the cache; inline legacy texts are content-addressed. Parser and tokenizer versions are explicit.
    func cacheKey() throws -> String {
        if let text { return VocabularyIndex.digest("parser1:tokenizer\(VocabularyTokenizer.version):\(fileExtension):\(text)") }
        guard let url else { throw ReadingVocabularyError.missingItem }
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = [url.path, fileExtension, String(describing: values[.size]),
                     String(describing: (values[.modificationDate] as? Date)?.timeIntervalSince1970),
                     String(describing: (values[.creationDate] as? Date)?.timeIntervalSince1970),
                     String(describing: values[.systemFileNumber])].joined(separator: "|")
        return VocabularyIndex.digest("parser1:tokenizer\(VocabularyTokenizer.version):\(stamp)")
    }
}

private final class VocabularyDatabase {
    enum Value { case text(String), int(Int64) }
    private var connection: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL?) throws {
        var initialized = false
        defer {
            if !initialized {
                for statement in statements.values { sqlite3_finalize(statement) }
                statements.removeAll()
                sqlite3_close(connection)
                connection = nil
            }
        }
        if let url {
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
        guard sqlite3_open_v2(url?.path ?? ":memory:", &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { throw failure() }
        try run("PRAGMA journal_mode=WAL")
        try run("CREATE TABLE IF NOT EXISTS word(id INTEGER PRIMARY KEY, language TEXT NOT NULL, form TEXT NOT NULL, UNIQUE(language,form))")
        try run("CREATE TABLE IF NOT EXISTS known(word_id INTEGER PRIMARY KEY)")
        try run("CREATE TABLE IF NOT EXISTS source(id TEXT PRIMARY KEY)")
        try run("CREATE TABLE IF NOT EXISTS source_form(source_id TEXT NOT NULL, form TEXT NOT NULL, PRIMARY KEY(source_id,form)) WITHOUT ROWID")
        try run("CREATE TABLE IF NOT EXISTS book(id TEXT PRIMARY KEY,language TEXT NOT NULL,revision TEXT NOT NULL,total_count INTEGER NOT NULL,new_count INTEGER NOT NULL CHECK(new_count>=0 AND new_count<=total_count))")
        try run("CREATE TABLE IF NOT EXISTS book_word(book_id TEXT NOT NULL,word_id INTEGER NOT NULL,PRIMARY KEY(book_id,word_id)) WITHOUT ROWID")
        try run("CREATE INDEX IF NOT EXISTS book_word_by_word ON book_word(word_id,book_id)")
        try run("CREATE TABLE IF NOT EXISTS book_source(book_id TEXT NOT NULL,source_id TEXT NOT NULL,PRIMARY KEY(book_id,source_id)) WITHOUT ROWID")
        initialized = true
    }
    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(connection)
    }
    private func failure() -> NSError {
        NSError(domain: "VocabularyIndex", code: Int(sqlite3_errcode(connection)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
    }
    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        let stmt: OpaquePointer
        if let cached = statements[sql] { stmt = cached }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
            statements[sql] = prepared; stmt = prepared
        }
        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
        for (offset, value) in values.enumerated() {
            let code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(stmt, Int32(offset + 1), text, -1, transient)
            case .int(let number): code = sqlite3_bind_int64(stmt, Int32(offset + 1), number)
            }
            guard code == SQLITE_OK else { throw failure() }
        }
        return stmt
    }
    func run(_ sql: String, _ values: [Value] = []) throws {
        let stmt = try statement(sql, values)
        defer { sqlite3_reset(stmt) }
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW { status = sqlite3_step(stmt) }
        guard status == SQLITE_DONE else { throw failure() }
    }
    func rows(_ sql: String, _ values: [Value] = []) throws -> [[String]] {
        let stmt = try statement(sql, values)
        defer { sqlite3_reset(stmt) }
        var result: [[String]] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_text(stmt, $0)) })
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }
    func word(_ language: String, _ form: String) throws -> Int64 {
        try run("INSERT OR IGNORE INTO word(language,form) VALUES (?,?)", [.text(language), .text(form)])
        return Int64(try rows("SELECT id FROM word WHERE language=? AND form=?", [.text(language), .text(form)])[0][0])!
    }
    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do { try body(); try run("COMMIT") }
        catch { try? run("ROLLBACK"); throw error }
    }
}
