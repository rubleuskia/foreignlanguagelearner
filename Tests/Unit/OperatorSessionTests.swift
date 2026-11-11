import XCTest
@testable import ForeignLanguageLearner

final class OperatorSessionTests: XCTestCase {
    private let api = BuiltinLibraryService.baseURL
    private func credentials(expired: Bool = true) -> OperatorCredentials {
        .init(clientID: "client", apiURL: api, username: "operator", accessToken: "old-access",
              refreshToken: "refresh", expiresAt: Date().addingTimeInterval(expired ? -10 : 900))
    }
    private func response(_ json: [String: Any], status: Int = 200) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: api, statusCode: status,
            httpVersion: nil, headerFields: nil)!)
    }
    private func tokens() throws -> (Data, HTTPURLResponse) {
        try response(["AuthenticationResult": ["AccessToken": "new-access", "ExpiresIn": 900]])
    }
    func testExpiredSessionRefreshesAndSurvivesRelaunchWithoutPassword() async throws {
        let store = LibraryMemoryStore(credentials())
        let client = LibraryHTTPClient([.success(try tokens())])
        let session = OperatorSession(clientID: "client", store: store, client: client)
        let lease = try await session.lease()
        XCTAssertEqual(lease.token, "new-access")
        let requests = await client.requests
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        XCTAssertEqual(body["AuthFlow"] as? String, "REFRESH_TOKEN_AUTH")
        XCTAssertEqual((body["AuthParameters"] as? [String: String]), ["REFRESH_TOKEN": "refresh"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(store.value?.refreshToken, "refresh")
        let relaunched = OperatorSession(clientID: "client", store: store, client: client)
        let next = try await relaunched.lease()
        XCTAssertEqual(next.token, lease.token)
        let count = await client.requests.count
        XCTAssertEqual(count, 1)
    }
    func testLoginChecksOperatorProfileAndStoresOnlySessionCredentials() async throws {
        let store = LibraryMemoryStore(nil)
        let client = LibraryHTTPClient([.success(try response(["AuthenticationResult": [
            "AccessToken": "access", "RefreshToken": "new-refresh", "ExpiresIn": 900]])),
            .success(try response(["role": "operator"]))])
        let session = OperatorSession(clientID: "client", store: store, client: client)
        try await session.signIn(username: "operator", password: "not-persisted")
        XCTAssertEqual(store.value?.refreshToken, "new-refresh")
        XCTAssertFalse(String(data: try JSONEncoder().encode(store.value), encoding: .utf8)!.contains("not-persisted"))
        let requests = await client.requests
        XCTAssertEqual(requests[1].url?.path, "/v1/me")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access")
    }
    func testOtherPoolUserCannotSaveLibrarySession() async throws {
        let store = LibraryMemoryStore(nil)
        let client = LibraryHTTPClient([.success(try response(["AuthenticationResult": [
            "AccessToken": "access", "RefreshToken": "refresh", "ExpiresIn": 900]])),
            .success(try response([:], status: 403))])
        let session = OperatorSession(clientID: "client", store: store, client: client)
        do { try await session.signIn(username: "other", password: "password"); XCTFail() }
        catch { XCTAssertNil(store.value) }
    }
    func testTemporaryRefreshFailurePreservesSessionButRevocationClearsIt() async throws {
        let store = LibraryMemoryStore(credentials())
        let client = LibraryHTTPClient([.failure(URLError(.notConnectedToInternet)),
            .success(try response(["__type": "NotAuthorizedException"], status: 400))])
        let session = OperatorSession(clientID: "client", store: store, client: client)
        do { _ = try await session.lease(); XCTFail() } catch { XCTAssertNotNil(store.value) }
        do { _ = try await session.lease(); XCTFail() } catch { XCTAssertNil(store.value) }
    }
    func testLibraryRefreshesAfter401AndRetriesOnlyOneGet() async throws {
        let store = LibraryMemoryStore(credentials(expired: false))
        let auth = LibraryHTTPClient([.success(try tokens())])
        let session = OperatorSession(clientID: "client", store: store, client: auth)
        let apiClient = LibraryHTTPClient([.success(try response([:], status: 401)),
            .success(try response(["books": []]))])
        let books = try await BuiltinLibraryService(authentication: session, client: apiClient).books()
        XCTAssertTrue(books.isEmpty)
        let requests = await apiClient.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer old-access", "Bearer new-access"])
        let refreshCount = await auth.requests.count
        XCTAssertEqual(refreshCount, 1)
    }
    func testSecond401DoesNotLoopAnd403DoesNotRefresh() async throws {
        for status in [401, 403] {
            let store = LibraryMemoryStore(credentials(expired: false))
            let auth = LibraryHTTPClient([.success(try tokens())])
            let session = OperatorSession(clientID: "client", store: store, client: auth)
            let apiClient = LibraryHTTPClient([.success(try response([:], status: status)),
                .success(try response([:], status: status))])
            do { _ = try await BuiltinLibraryService(authentication: session, client: apiClient).books(); XCTFail() }
            catch { }
            let requests = await apiClient.requests
            let refreshCount = await auth.requests.count
            XCTAssertEqual(requests.count, status == 401 ? 2 : 1)
            XCTAssertEqual(refreshCount, status == 401 ? 1 : 0)
        }
    }
    func testConcurrentExpiredRequestsShareOneSuccessfulRefresh() async throws {
        let store = LibraryMemoryStore(credentials())
        let client = LibraryHTTPClient([.success(try tokens())], delayFirst: true)
        let session = OperatorSession(clientID: "client", store: store, client: client)
        async let first = session.lease()
        async let second = session.lease()
        let leases = try await [first, second]
        XCTAssertEqual(leases.map(\.token), ["new-access", "new-access"])
        let count = await client.requests.count
        XCTAssertEqual(count, 1)
    }
    func testConcurrentExpiredRequestsShareRefreshAndLogoutCannotBeUndone() async throws {
        let store = LibraryMemoryStore(credentials())
        let client = LibraryHTTPClient([.success(try tokens()), .success(try response([:]))], delayFirst: true)
        let session = OperatorSession(clientID: "client", store: store, client: client)
        let first = Task { try await session.lease() }
        let second = Task { try await session.lease() }
        while await client.requests.isEmpty { await Task.yield() }
        try await session.signOut()
        do { _ = try await first.value; XCTFail() } catch { }
        do { _ = try await second.value; XCTFail() } catch { }
        XCTAssertNil(store.value)
        let requests = await client.requests
        XCTAssertEqual(requests.count, 2) // One shared refresh and one revocation.
    }
}

private final class LibraryMemoryStore: OperatorCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OperatorCredentials?
    init(_ value: OperatorCredentials?) { stored = value }
    var value: OperatorCredentials? { lock.withLock { stored } }
    func load() throws -> OperatorCredentials? { value }
    func save(_ value: OperatorCredentials?) throws { lock.withLock { stored = value } }
}
private actor LibraryHTTPClient: ContextAnalysisHTTPClient {
    var requests: [URLRequest] = []
    var script: [Result<(Data, HTTPURLResponse), Error>]
    let delayFirst: Bool
    init(_ script: [Result<(Data, HTTPURLResponse), Error>], delayFirst: Bool = false) {
        self.script = script; self.delayFirst = delayFirst
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let first = requests.count == 1
        guard !script.isEmpty else { throw URLError(.badServerResponse) }
        let result = script.removeFirst()
        if delayFirst && first { try? await Task.sleep(for: .milliseconds(150)) }
        return try result.get()
    }
}
