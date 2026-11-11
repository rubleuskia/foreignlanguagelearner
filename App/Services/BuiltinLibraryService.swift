import Foundation
import CryptoKit

struct LibraryBook: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let language: String
    let bytes: Int64
    let sha256: String
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
