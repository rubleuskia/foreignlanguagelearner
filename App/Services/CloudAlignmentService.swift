import Foundation

struct CloudAlignmentJob: Codable, Identifiable, Sendable {
    let job_id: String
    let title: String
    let language: String
    let status: String
    let progress: Int
    let error_code: String?
    var created_at: Int? = nil
    var id: String { job_id }
    var terminal: Bool { ["succeeded", "succeeded_with_review", "failed"].contains(status) }
    var succeeded: Bool { status == "succeeded" || status == "succeeded_with_review" }
    var statusText: String {
        let message = switch status {
        case "awaiting_upload": "Ready to upload"
        case "uploaded": "Artifacts uploaded"
        case "queued": "Waiting in queue"
        case "downloading": "Loading artifacts"
        case "preparing": "Preparing audio and text"
        case "aligning": "Aligning book"
        case "validating": "Checking alignment"
        case "publishing": "Saving synchronized book"
        case "succeeded": "Alignment complete"
        case "succeeded_with_review": "Alignment complete — review recommended"
        case "failed": "Alignment failed"
        default: "Checking status"
        }
        return AppLanguage.text(message)
    }
}

actor CloudAlignmentService {
    private let authentication: OperatorSession
    private let client: any ContextAnalysisHTTPClient
    private let session: URLSession
    private let baseURL: URL
    init(authentication: OperatorSession = .shared, baseURL: URL = BuiltinLibraryService.baseURL,
         client: any ContextAnalysisHTTPClient = URLSessionContextAnalysisHTTPClient(
            session: URLSession(configuration: .ephemeral))) {
        self.authentication = authentication; self.client = client; self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config)
    }
    struct Jobs: Decodable { let jobs: [CloudAlignmentJob]; let cursor: String? }
    private struct Upload: Decodable { let url: URL; let headers: [String: String] }
    private struct Download: Decodable { let url: URL; let bytes: Int; let sha256: String }
    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil,
                                        key: String? = nil, cursor: String? = nil) async throws -> T {
        var lease = try await authentication.lease()
        func send(_ token: String) async throws -> (Data, HTTPURLResponse) {
            var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
            if let cursor { components.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
            return try await client.data(for: request)
        }
        var (data, response) = try await send(lease.token)
        try await authentication.validate(lease)
        if response.statusCode == 401 {
            lease = try await authentication.lease(rejected: lease)
            (data, response) = try await send(lease.token)
            try await authentication.validate(lease)
        }
        if response.statusCode == 401 { throw OperatorSessionError.signInRequired }
        if response.statusCode == 403 { throw OperatorSessionError.denied }
        guard response.statusCode == 200 else {
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let code = (value?["error"] as? [String: String])?["code"] ?? "HTTP_\(response.statusCode)"
            throw CloudAlignmentFiles.invalid(Self.message(for: code))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func jobs() async throws -> [CloudAlignmentJob] {
        var jobs: [CloudAlignmentJob] = [], cursor: String?
        repeat {
            let page: Jobs = try await request("v1/book-alignments", cursor: cursor)
            jobs += page.jobs; cursor = page.cursor
        } while cursor != nil
        return jobs.sorted { ($0.created_at ?? 0, $0.id) > ($1.created_at ?? 0, $1.id) }
    }
    nonisolated static func message(for code: String) -> String {
        let text = switch code {
        case "INPUT_TOO_LARGE": "The prepared ZIP exceeds 100 MB. Choose smaller files."
        case "CHECKSUM_MISMATCH": "The uploaded file failed verification. Upload it again."
        case "RESULT_EXPIRED": "The result has expired. Create a new alignment."
        case "INVALID_TEXT": "Could not read the book text. Use matching UTF-8 TXT or EPUB."
        case "INVALID_AUDIO": "Could not decode the audio. Use valid MP3, M4A or WAV tracks."
        case "INVALID_ARCHIVE": "The audio archive is invalid or damaged. Choose another ZIP."
        case "ALIGNMENT_FAILED", "INVALID_TIMINGS": "Could not align this book. Check that the narration matches the complete text."
        case "UPLOAD_NOT_FOUND": "The upload is incomplete. Upload the artifacts again."
        case "STATE_CHANGED", "INVALID_STATE": "The request changed. Refresh its status."
        default: "Cloud alignment is temporarily unavailable. Please try again."
        }
        return AppLanguage.text(text)
    }
    func status(_ id: String) async throws -> CloudAlignmentJob { try await request("v1/book-alignments/\(id)") }
    func create(title: String, language: String, package: CloudAlignmentFiles.Package, key: String) async throws -> CloudAlignmentJob {
        let body = try JSONSerialization.data(withJSONObject: ["title": title, "language": language,
            "size_bytes": package.bytes, "sha256": package.sha256])
        return try await request("v1/book-alignments", method: "POST", body: body, key: key)
    }
    func complete(_ id: String) async throws -> CloudAlignmentJob {
        try await request("v1/book-alignments/\(id)/complete", method: "POST")
    }
    func start(_ id: String) async throws -> CloudAlignmentJob {
        try await request("v1/book-alignments/\(id)/start", method: "POST")
    }
    func upload(_ id: String, file: URL) async throws -> CloudAlignmentJob {
        let info: Upload = try await request("v1/book-alignments/\(id)/upload", method: "POST")
        try validateS3(info.url)
        var request = URLRequest(url: info.url); request.httpMethod = "PUT"
        for (key, value) in info.headers { request.setValue(value, forHTTPHeaderField: key) }
        let (_, response) = try await session.upload(for: request, fromFile: file)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudAlignmentFiles.invalid("Upload failed. Try uploading again.") }
        return try await complete(id)
    }
    func download(_ id: String) async throws -> URL {
        let info: Download = try await request("v1/book-alignments/\(id)/result")
        try validateS3(info.url)
        guard info.bytes > 0, info.bytes <= 4 * 1024 * 1024 * 1024 else { throw CloudAlignmentFiles.invalid("Invalid result size.") }
        let (temporary, response) = try await session.download(from: info.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudAlignmentFiles.invalid("Could not download the synchronized book.") }
        let package = try await Task.detached { try CloudAlignmentFiles.inspect(temporary) }.value
        guard package.bytes == info.bytes, package.sha256 == info.sha256 else { throw CloudAlignmentFiles.invalid("The downloaded book is damaged. Try again.") }
        try CloudAlignmentFiles.initialize()
        let result = CloudAlignmentFiles.root.appending(path: "result-\(id).zip")
        if FileManager.default.fileExists(atPath: result.path) { try FileManager.default.removeItem(at: result) }
        try FileManager.default.moveItem(at: temporary, to: result)
        return result
    }
    private func validateS3(_ url: URL) throws {
        guard url.scheme == "https", url.host?.hasSuffix(".s3.eu-north-1.amazonaws.com") == true,
              url.user == nil, url.password == nil else { throw CloudAlignmentFiles.invalid("Invalid artifact address.") }
    }
}
