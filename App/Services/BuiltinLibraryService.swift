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

    private func request<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        guard let token = try OperatorAccessTokenStore.load(), !token.isEmpty else {
            throw failure("Добавьте access token operator в настройках.")
        }
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw failure("Нет ответа от библиотеки.") }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw failure("Токен истёк или доступ запрещён. Обновите access token operator в настройках.")
        }
        guard http.statusCode == 200 else { throw failure("Библиотека недоступна (\(http.statusCode)). Повторите попытку.") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func books() async throws -> [LibraryBook] {
        try await request("v1/library/books", as: Catalog.self).books
    }
    func download(_ book: LibraryBook) async throws -> URL {
        let info = try await request("v1/library/books/\(book.id)/download", as: Download.self)
        guard info.url.scheme == "https", info.url.host?.hasSuffix(".amazonaws.com") == true,
              info.bytes == book.bytes, info.sha256 == book.sha256 else {
            throw failure("Каталог изменился. Обновите список книг.")
        }
        let (temporary, response) = try await session.download(from: info.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw failure("Не удалось скачать книгу. Повторите попытку.")
        }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk); count += Int64(chunk.count)
        }
        guard count == book.bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == book.sha256 else {
            throw failure("Файл повреждён. Скачайте книгу ещё раз.")
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID()).zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "BuiltinLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
