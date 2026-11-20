import Foundation
import CryptoKit

struct ExamIdentity: Sendable {
    let scopeID: String
    let userID: String
    let mode: CloudProviderMode
}

struct ExamAPIError: LocalizedError, Sendable {
    let code: String
    var status: Int? = nil
    var payload: Data? = nil
    var isConflict: Bool { status == 409 || code.contains("CONFLICT") || code == "VERSION_MISMATCH" || ["EXAM_ATTEMPT_SUBMITTED", "EXAM_SECTION_SUBMITTED"].contains(code) }
    var isRejectedChange: Bool {
        [400, 413, 422].contains(status ?? 0) || ["TOO_MANY_EXAM_TOKENS", "UNKNOWN_EXAM_RESPONSE",
            "INVALID_EXAM_RESPONSE", "EXAM_RECORD_TOO_LARGE", "INVALID_EXAM_PROGRESS"].contains(code)
    }
    var errorDescription: String? {
        if isConflict { return "This attempt changed on another device. Your local answers are saved." }
        switch code {
        case "INVALID_EXAM_MATERIAL": return "The exam material failed verification. Download it again."
        case "UNSUPPORTED_EXAM_SCHEMA": return "This exam uses an unsupported format."
        case "ACCOUNT_CHANGED": return "The exam account or provider changed. Reopen the exam."
        case "SIGN_IN_REQUIRED": return "Sign in using the selected translation provider in Settings."
        case "DEVICE_LOCKED": return AppLanguage.text("Unlock your device to access the saved exam session.")
        case "STORAGE_FAILED": return "Could not save the attempt. Your last saved answers are retained."
        case "TOO_MANY_EXAM_TOKENS": return "Too many answers in a response field. Your local answers are saved; correct the answer and retry."
        default: return "Exam service unavailable (\(code)). Local progress is saved."
        }
    }
}

/// Authorizes every request in the same identity domain as the translation provider.
actor ExamAPIClient {
    private let operatorSession: OperatorSession
    private let cloudSession: CloudSession
    private let client: any ContextAnalysisHTTPClient
    private let modeProvider: @Sendable () -> CloudProviderMode

    init(operatorSession: OperatorSession = .shared, cloudSession: CloudSession = .shared,
         client: any ContextAnalysisHTTPClient = URLSessionContextAnalysisHTTPClient(session: URLSession(configuration: .ephemeral)),
         modeProvider: @escaping @Sendable () -> CloudProviderMode = { TranslationRequestSettings.current.mode }) {
        self.operatorSession = operatorSession; self.cloudSession = cloudSession
        self.client = client; self.modeProvider = modeProvider
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    private static var localConfiguration: (URL, String)? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["EXAM_API_URL"], let url = URL(string: raw), url.scheme == "http",
              ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let token = env["EXAM_LOCAL_API_TOKEN"], !token.isEmpty else { return nil }
        return (url, token)
    }
    #endif

    func identity() async throws -> ExamIdentity {
        let mode = modeProvider()
        #if DEBUG
        if let (url, _) = Self.localConfiguration {
            return ExamIdentity(scopeID: Self.digest("local|\(mode.rawValue)|\(url.absoluteString)"), userID: "local-pilot", mode: mode)
        }
        #endif
        if mode == .subscription {
            let lease = try await cloudSession.lease()
            return ExamIdentity(scopeID: Self.digest("cloud|\(lease.scopeID)|\(lease.userID)"), userID: lease.userID, mode: mode)
        }
        guard let credentials = try await operatorSession.credentialsSnapshot(), !credentials.username.isEmpty,
              let subject = Self.localSubject(credentials.accessToken) else { throw ExamAPIError(code: "SIGN_IN_REQUIRED") }
        return ExamIdentity(scopeID: Self.digest("operator|\(BuiltinLibraryService.baseURL.absoluteString)|\(OperatorSession.clientID)|\(subject)"), userID: subject, mode: mode)
    }

    /// Used only to partition local files; the server remains the authority for authentication.
    private static func localSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let bytes = Data(base64Encoded: value), let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let sub = json["sub"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    func send(_ path: String, method: String = "GET", body: Data? = nil, idempotencyKey: UUID? = nil,
              expectedScope: String? = nil, timeout: TimeInterval = 25) async throws -> Data {
        let identity = try await identity()
        if let expectedScope, expectedScope != identity.scopeID { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
        let route = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard route.hasPrefix("v1/exams") || route.hasPrefix("v1/exam-attempts") || route.hasPrefix("v1/exam-assessments"),
              !route.contains(".."), !route.contains("://"), !route.contains("?") else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
        #if DEBUG
        if let (base, token) = Self.localConfiguration {
            let data = try await direct(base: base, route: route, method: method, body: body, token: token, idempotencyKey: idempotencyKey, timeout: timeout)
            guard try await self.identity().scopeID == identity.scopeID else { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
            return data
        }
        #endif
        if identity.mode == .subscription {
            let lease = try await cloudSession.lease()
            let bytes: Data
            do { bytes = try await cloudSession.send(route, method: method, body: body, idempotencyKey: idempotencyKey, expected: lease, timeout: timeout) }
            catch let error as CloudAPIError { throw ExamAPIError(code: error.code) }
            guard try await self.identity().scopeID == identity.scopeID else { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
            return bytes
        }
        var lease = try await operatorSession.lease()
        do {
            let bytes = try await direct(base: BuiltinLibraryService.baseURL, route: route, method: method, body: body, token: lease.token, idempotencyKey: idempotencyKey, timeout: timeout)
            try await operatorSession.validate(lease)
            guard try await self.identity().scopeID == identity.scopeID else { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
            return bytes
        } catch let error as ExamAPIError where error.status == 401 {
            // A rejected authentication has not applied a mutation. Preserve its exact idempotency key.
            lease = try await operatorSession.lease(rejected: lease)
            let bytes = try await direct(base: BuiltinLibraryService.baseURL, route: route, method: method, body: body, token: lease.token, idempotencyKey: idempotencyKey, timeout: timeout)
            try await operatorSession.validate(lease)
            guard try await self.identity().scopeID == identity.scopeID else { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
            return bytes
        }
    }

    private func direct(base: URL, route: String, method: String, body: Data?, token: String,
                        idempotencyKey: UUID?, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: base.appending(path: route))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey { request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await client.data(for: request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = (root?["error"] as? [String: Any])?["code"] as? String ?? "HTTP_\(response.statusCode)"
            throw ExamAPIError(code: code, status: response.statusCode, payload: data)
        }
        return data
    }

    func catalog(expectedScope: String) async throws -> [ExamCatalogEntry] {
        let bytes = try await send("v1/exams", expectedScope: expectedScope)
        let catalog = try ExamJSON.decoder().decode(ExamCatalogEnvelope.self, from: bytes)
        guard catalog.schemaVersion == "1.1" else { throw ExamAPIError(code: "UNSUPPORTED_EXAM_SCHEMA") }
        return catalog.exams
    }

    func package(examID: String, revision: String, expectedScope: String) async throws -> ExamPackage {
        let route = try Self.revisionRoute(examID: examID, revision: revision)
        let bytes = try await send(route, expectedScope: expectedScope)
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard let exam = object?["exam"] as? [String: Any] else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
        try Self.rejectPrivateKeys(exam)
        let envelope = try ExamJSON.decoder().decode(ExamPackageEnvelope.self, from: bytes)
        var package = envelope.exam; package.audio = envelope.audio
        guard package.schemaVersion == "1.1", package.id == examID, package.revision == revision,
              !package.sources.isEmpty, package.sources.allSatisfy({ ["paper", "audio"].contains($0.id) }) else {
            throw ExamAPIError(code: "INVALID_EXAM_MATERIAL")
        }
        return package
    }

    static func rejectPrivateKeys(_ value: Any) throws {
        let forbidden: Set<String> = ["grading", "accepted_answers", "reference_answer", "source_accepted_option_ids", "source_reference_answer", "rubric", "assessment_contract", "ai_contract"]
        if let object = value as? [String: Any] {
            guard forbidden.isDisjoint(with: Set(object.keys)) else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
            if let sourceID = object["source_id"] as? String, sourceID == "keys" { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
            for child in object.values { try rejectPrivateKeys(child) }
        } else if let array = value as? [Any] { for child in array { try rejectPrivateKeys(child) } }
    }

    static func revisionRoute(examID: String, revision: String) throws -> String {
        guard examID.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              revision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
        return "v1/exams/\(examID)/revisions/\(revision)"
    }

    func download(_ source: ExamSource, package: ExamPackage, expectedScope: String) async throws -> Data {
        guard ["paper", "audio"].contains(source.id), source.bytes > 0, source.bytes <= 128 * 1024 * 1024 else {
            throw ExamAPIError(code: "INVALID_EXAM_MATERIAL")
        }
        let route = try Self.revisionRoute(examID: package.id, revision: package.revision) + "/sources/\(source.id)"
        struct Descriptor: Decodable { let download_path: String?; let download_url: URL?; let bytes: Int64; let sha256: String; let media_type: String }
        let info = try ExamJSON.decoder().decode(Descriptor.self, from: await send(route + "/download", expectedScope: expectedScope))
        guard info.bytes == source.bytes,
              info.sha256 == source.sha256, info.media_type == source.mediaType else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
        let bytes: Data
        if let url = info.download_url {
            guard info.download_path == nil, S3ArtifactURL.isAllowed(url) else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
            guard try await identity().scopeID == expectedScope else { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
            // Signed object requests carry no API Authorization header or cookies.
            var request = URLRequest(url: url)
            request.timeoutInterval = 900
            let downloader = URLSessionBookDownloadClient()
            let (file, response) = try await downloader.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            guard response.statusCode == 200, let finalURL = response.url, S3ArtifactURL.isAllowed(finalURL),
                  (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == source.bytes else {
                throw ExamAPIError(code: "INVALID_EXAM_MATERIAL")
            }
            bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            guard try await identity().scopeID == expectedScope else { throw ExamAPIError(code: "ACCOUNT_CHANGED") }
        } else {
            guard info.download_path == "/" + route + "/content" else { throw ExamAPIError(code: "INVALID_EXAM_MATERIAL") }
            bytes = try await send(info.download_path!, expectedScope: expectedScope, timeout: 900)
        }
        guard Int64(bytes.count) == source.bytes,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == source.sha256 else {
            throw ExamAPIError(code: "INVALID_EXAM_MATERIAL")
        }
        return bytes
    }
}
