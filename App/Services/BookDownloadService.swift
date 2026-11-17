import CryptoKit
import Foundation

struct BookDownload: Decodable, Sendable {
    let url: URL
    let bytes: Int64
    let sha256: String
}

/// Validate the destination without rewriting the path or opaque signing query.
enum S3ArtifactURL {
    private static let endpoints = [
        "s3.amazonaws.com",
        "s3.eu-north-1.amazonaws.com",
        "s3.dualstack.eu-north-1.amazonaws.com",
    ]

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              let endpoint = endpoints.first(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
        let path = url.path.split(separator: "/")
        if host == endpoint {
            return path.count >= 2 && validBucket(String(path[0]))
        }
        let bucket = String(host.dropLast(endpoint.count + 1))
        return !path.isEmpty && validBucket(bucket)
    }

    private static func validBucket(_ value: String) -> Bool {
        (3...63).contains(value.utf8.count)
            && value.range(of: "^[a-z0-9][a-z0-9.-]*[a-z0-9]$", options: .regularExpression) != nil
            && !value.contains("..")
            && value.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) == nil
    }
}

final class S3RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(S3ArtifactURL.isAllowed) == true ? request : nil)
    }
}

protocol BookDownloadClient: Sendable {
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

final class URLSessionBookDownloadClient: BookDownloadClient {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 3600
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: S3RedirectPolicy(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (file, response) = try await session.download(for: request)
        guard let response = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: file)
            throw BookDownloadError.downloadFailed
        }
        return (file, response)
    }
}

enum BookDownloadError: LocalizedError, Equatable {
    case invalidAddress, invalidMetadata, downloadFailed, damagedFile

    var errorDescription: String? {
        let message = switch self {
        case .invalidAddress: "Invalid artifact address."
        case .invalidMetadata: "The catalog changed. Refresh the book list."
        case .downloadFailed: "Could not download the book. Please try again."
        case .damagedFile: "The file is damaged. Download the book again."
        }
        return AppLanguage.text(message)
    }
}

actor BookDownloadService {
    static let shared = BookDownloadService()
    static let maximumBytes: Int64 = 4 * 1024 * 1024 * 1024
    private let client: any BookDownloadClient

    init(client: any BookDownloadClient = URLSessionBookDownloadClient()) { self.client = client }

    func download(_ book: BookDownload) async throws -> URL {
        try Task.checkCancellation()
        guard S3ArtifactURL.isAllowed(book.url) else { throw BookDownloadError.invalidAddress }
        guard book.bytes > 0, book.bytes <= Self.maximumBytes, book.sha256.utf8.count == 64,
              book.sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw BookDownloadError.invalidMetadata
        }
        let (temporary, response) = try await client.download(for: URLRequest(url: book.url))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let finalURL = response.url, S3ArtifactURL.isAllowed(finalURL) else {
            throw BookDownloadError.invalidAddress
        }
        guard response.statusCode == 200 else { throw BookDownloadError.downloadFailed }

        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        var hash = SHA256(), count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= book.bytes else { throw BookDownloadError.damagedFile }
            hash.update(data: chunk)
        }
        let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == book.bytes, checksum == book.sha256.lowercased() else { throw BookDownloadError.damagedFile }
        try Task.checkCancellation()
        let destination = FileManager.default.temporaryDirectory.appending(path: "book-download-\(UUID()).zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
