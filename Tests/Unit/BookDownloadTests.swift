import CryptoKit
import Foundation
import XCTest
@testable import ForeignLanguageLearner

final class BookDownloadTests: XCTestCase {
    private let url = URL(string: "https://test-library.s3.amazonaws.com/library/book.zip?versionId=version&X-Amz-Signature=a%2Fb%2Bc%3D")!

    func testS3VirtualHostedAndPathStyleEndpoints() {
        for endpoint in ["s3.amazonaws.com", "s3.eu-north-1.amazonaws.com", "s3.dualstack.eu-north-1.amazonaws.com"] {
            for address in ["https://test-library.\(endpoint)/library/book.zip",
                            "https://\(endpoint)/test-library/library/book.zip"] {
                XCTAssertTrue(S3ArtifactURL.isAllowed(URL(string: address)!), address)
            }
        }
        XCTAssertTrue(S3ArtifactURL.isAllowed(URL(string: "https://test-library.s3.amazonaws.com:443/book.zip")!))
        XCTAssertTrue(S3ArtifactURL.isAllowed(URL(string: "https://test.library.s3.eu-north-1.amazonaws.com/book.zip")!))
    }

    func testRejectsUntrustedHostsCredentialsAndMalformedDestinations() {
        for address in [
            "http://test-library.s3.amazonaws.com/book.zip",
            "https://test-library.s3.amazonaws.com.evil.test/book.zip",
            "https://s3.amazonaws.com.evil.test/test-library/book.zip",
            "https://evil.test/book.zip", "https://ec2.eu-north-1.amazonaws.com/book.zip",
            "https://test-library.s3.eu-west-1.amazonaws.com/book.zip",
            "https://user@test-library.s3.amazonaws.com/book.zip",
            "https://user:password@test-library.s3.amazonaws.com/book.zip",
            "https://test-library.s3.amazonaws.com:8443/book.zip",
            "https://test-library.s3.amazonaws.com/book.zip#fragment",
            "https://test-library.s3.amazonaws.com/", "https://s3.amazonaws.com/test-library",
            "https://a.s3.amazonaws.com/book.zip", "https://test..library.s3.amazonaws.com/book.zip",
            "https://192.168.1.1.s3.amazonaws.com/book.zip", "file:///tmp/book.zip",
        ] {
            XCTAssertFalse(S3ArtifactURL.isAllowed(URL(string: address)!), address)
        }
    }

    func testRedirectPolicyPreservesSignedRequestAndRejectsOtherHosts() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        defer { task.cancel() }
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let policy = S3RedirectPolicy()
        for destination in [url, URL(string: "https://evil.test/book.zip")!] {
            let request = URLRequest(url: destination)
            let result: URLRequest? = await withCheckedContinuation { continuation in
                policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertEqual(result?.url, destination == url ? url : nil)
        }
    }

    func testGlobalSignedURLDownloadsWithoutRewritingAndChecksIntegrity() async throws {
        let fixture = try Fixture(url: url)
        defer { fixture.remove() }
        let client = StubClient(file: fixture.file, response: fixture.response)
        let service = BookDownloadService(client: client)
        let descriptor = BookDownload(url: url, bytes: fixture.book.bytes, sha256: fixture.book.sha256.uppercased())
        let downloaded = try await service.download(descriptor)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        XCTAssertEqual(try Data(contentsOf: downloaded), fixture.data)
        XCTAssertEqual(downloaded.pathExtension, "zip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let requests = await client.captured()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, url.absoluteString)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testInvalidMetadataIsRejectedBeforeNetwork() async throws {
        let fixture = try Fixture(url: url)
        defer { fixture.remove() }
        let client = StubClient(file: fixture.file, response: fixture.response)
        let service = BookDownloadService(client: client)
        for descriptor in [
            BookDownload(url: url, bytes: 0, sha256: fixture.book.sha256),
            BookDownload(url: url, bytes: BookDownloadService.maximumBytes + 1, sha256: fixture.book.sha256),
            BookDownload(url: url, bytes: 1, sha256: "bad"),
            BookDownload(url: url, bytes: 1, sha256: String(repeating: "x", count: 64)),
            BookDownload(url: url, bytes: 1, sha256: String(repeating: "a", count: 64) + "\n"),
        ] {
            do { _ = try await service.download(descriptor); XCTFail("Invalid metadata accepted") }
            catch { XCTAssertEqual(error as? BookDownloadError, .invalidMetadata) }
        }
        let requests = await client.captured()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testUntrustedInitialURLIsRejectedBeforeNetwork() async throws {
        let fixture = try Fixture(url: url)
        defer { fixture.remove() }
        let client = StubClient(file: fixture.file, response: fixture.response)
        let service = BookDownloadService(client: client)
        do {
            _ = try await service.download(BookDownload(url: URL(string: "https://evil.test/book.zip")!,
                bytes: fixture.book.bytes, sha256: fixture.book.sha256))
            XCTFail("Untrusted URL accepted")
        } catch { XCTAssertEqual(error as? BookDownloadError, .invalidAddress) }
        let requests = await client.captured()
        XCTAssertTrue(requests.isEmpty)
    }

    func testWrongSizeAndChecksumRemoveDownloadedTemporaryFile() async throws {
        for variant in 0..<3 {
            let fixture = try Fixture(url: url)
            defer { fixture.remove() }
            let client = StubClient(file: fixture.file, response: fixture.response)
            let descriptor = BookDownload(url: url,
                bytes: fixture.book.bytes + (variant == 0 ? -1 : variant == 1 ? 1 : 0),
                sha256: variant == 2 ? String(repeating: "0", count: 64) : fixture.book.sha256)
            do { _ = try await BookDownloadService(client: client).download(descriptor); XCTFail("Damaged file accepted") }
            catch { XCTAssertEqual(error as? BookDownloadError, .damagedFile) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        }
    }

    func testFailedResponseAndUnsafeFinalURLRemoveDownloadedTemporaryFile() async throws {
        for unsafe in [false, true] {
            let fixture = try Fixture(url: url)
            defer { fixture.remove() }
            let response = HTTPURLResponse(url: unsafe ? URL(string: "https://evil.test/book.zip")! : url,
                statusCode: unsafe ? 200 : 403, httpVersion: nil, headerFields: nil)!
            let client = StubClient(file: fixture.file, response: response)
            do { _ = try await BookDownloadService(client: client).download(fixture.book); XCTFail("Bad response accepted") }
            catch { XCTAssertEqual(error as? BookDownloadError, unsafe ? .invalidAddress : .downloadFailed) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        }
    }

    func testCancellationAfterTransferRemovesDownloadedTemporaryFile() async throws {
        let fixture = try Fixture(url: url)
        defer { fixture.remove() }
        let client = PausedClient(file: fixture.file, response: fixture.response)
        let service = BookDownloadService(client: client)
        let download = Task { try await service.download(fixture.book) }
        await client.waitUntilStarted()
        download.cancel()
        await client.finish()
        do { _ = try await download.value; XCTFail("Cancelled download succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    private struct Fixture {
        let directory: URL
        let file: URL
        let data = Data("A downloaded book fixture".utf8)
        let response: HTTPURLResponse
        let book: BookDownload
        init(url: URL) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appending(path: "network-download.tmp")
            try data.write(to: file)
            response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            book = BookDownload(url: url, bytes: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private actor StubClient: BookDownloadClient {
        let file: URL
        let response: HTTPURLResponse
        private var requests: [URLRequest] = []
        init(file: URL, response: HTTPURLResponse) { self.file = file; self.response = response }
        func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
            requests.append(request)
            return (file, response)
        }
        func captured() -> [URLRequest] { requests }
    }

    private actor PausedClient: BookDownloadClient {
        let file: URL
        let response: HTTPURLResponse
        private var release: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        init(file: URL, response: HTTPURLResponse) { self.file = file; self.response = response }
        func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
            await withCheckedContinuation { continuation in
                release = continuation; started?.resume(); started = nil
            }
            return (file, response)
        }
        func waitUntilStarted() async {
            if release == nil { await withCheckedContinuation { started = $0 } }
        }
        func finish() { release?.resume(); release = nil }
    }
}
