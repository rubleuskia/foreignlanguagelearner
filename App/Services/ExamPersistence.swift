import Foundation
import CryptoKit

enum ExamSyncKind: String, Codable, Sendable { case create, update, submit }

struct ExamSyncEvent: Codable, Identifiable, Sendable {
    let id: UUID
    let attemptID: String
    let kind: ExamSyncKind
    var body: [String: ExamJSONValue]
    var sentBaseVersion: Int?
    let createdAt: Date
    init(attemptID: String, kind: ExamSyncKind, body: [String: ExamJSONValue], now: Date = Date()) {
        id = UUID(); self.attemptID = attemptID; self.kind = kind; self.body = body; createdAt = now
    }
}

struct ExamSyncConflict: Codable, Identifiable, Sendable {
    var id: String { attemptID }
    let attemptID: String
    let message: String
    var remote: ExamAttempt?
}

struct ExamLocalState: Codable, Sendable {
    let scopeID: String
    var deviceID: String
    var catalog: [ExamCatalogEntry]
    var attempts: [ExamAttempt]
    var outbox: [ExamSyncEvent]
    var conflicts: [ExamSyncConflict]
    init(scopeID: String, deviceID: String = UUID().uuidString.lowercased()) {
        self.scopeID = scopeID; self.deviceID = deviceID; catalog = []; attempts = []; outbox = []; conflicts = []
    }
}

/// One atomic state file commits an answer and its outbox event together.
/// Large, immutable source files are stored once per revision, outside that transaction.
@MainActor final class ExamPersistence {
    let root: URL
    private let manager: FileManager

    init(root: URL? = nil, manager: FileManager = .default) {
        self.manager = manager
        self.root = root ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Exams", directoryHint: .isDirectory)
    }

    private func directory(scopeID: String) throws -> URL {
        guard scopeID.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
        return root.appending(path: scopeID, directoryHint: .isDirectory)
    }
    private func create(_ directory: URL) throws { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
    private func save(_ data: Data, to url: URL) throws {
        try create(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func load(scopeID: String) throws -> ExamLocalState {
        let url = try directory(scopeID: scopeID).appending(path: "state.json")
        guard manager.fileExists(atPath: url.path) else { return ExamLocalState(scopeID: scopeID) }
        let state = try ExamJSON.decoder().decode(ExamLocalState.self, from: Data(contentsOf: url))
        guard state.scopeID == scopeID else { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
        return state
    }
    func commit(_ state: ExamLocalState) throws {
        let url = try directory(scopeID: state.scopeID).appending(path: "state.json")
        try save(ExamJSON.encoder().encode(state), to: url)
    }
    private func revisionDirectory(examID: String, revision: String, scopeID: String) throws -> URL {
        _ = try ExamAPIClient.revisionRoute(examID: examID, revision: revision)
        let digest = SHA256.hash(data: Data((examID + "|" + revision).utf8)).map { String(format: "%02x", $0) }.joined()
        return try directory(scopeID: scopeID).appending(path: "revisions/\(digest)", directoryHint: .isDirectory)
    }
    func savePackage(_ package: ExamPackage, scopeID: String) throws {
        try save(ExamJSON.encoder().encode(package), to: revisionDirectory(examID: package.id, revision: package.revision, scopeID: scopeID).appending(path: "student.json"))
    }
    func package(examID: String, revision: String, scopeID: String) throws -> ExamPackage? {
        let url = try revisionDirectory(examID: examID, revision: revision, scopeID: scopeID).appending(path: "student.json")
        guard manager.fileExists(atPath: url.path) else { return nil }
        let bytes = try Data(contentsOf: url)
        try ExamAPIClient.rejectPrivateKeys(JSONSerialization.jsonObject(with: bytes))
        let package = try ExamJSON.decoder().decode(ExamPackage.self, from: bytes)
        guard package.id == examID, package.revision == revision, package.schemaVersion == "1.1" else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
        return package
    }
    func sourceURL(_ source: ExamSource, package: ExamPackage, scopeID: String) throws -> URL {
        guard ["paper", "audio"].contains(source.id) else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
        let ext = source.mediaType == "audio/mpeg" ? "mp3" : "pdf"
        return try revisionDirectory(examID: package.id, revision: package.revision, scopeID: scopeID).appending(path: "\(source.id).\(ext)")
    }
    func verifiedSourceURL(_ source: ExamSource, package: ExamPackage, scopeID: String) throws -> URL? {
        let url = try sourceURL(source, package: package, scopeID: scopeID)
        guard manager.fileExists(atPath: url.path) else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), count: Int64 = 0
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            count += Int64(chunk.count); digest.update(data: chunk)
        }
        guard count == source.bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == source.sha256 else {
            throw ExamAPIError(code: "INVALID_EXAM_MATERIAL")
        }
        return url
    }
    func saveSource(_ bytes: Data, source: ExamSource, package: ExamPackage, scopeID: String) throws -> URL {
        guard Int64(bytes.count) == source.bytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == source.sha256 else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
        let url = try sourceURL(source, package: package, scopeID: scopeID)
        try save(bytes, to: url)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var resourceURL = url; try resourceURL.setResourceValues(values)
        return url
    }
}
