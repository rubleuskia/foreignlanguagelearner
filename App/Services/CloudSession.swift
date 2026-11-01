import Foundation
import Security
import CryptoKit

struct CloudCredentials: Codable, Sendable, Equatable {
    let scopeID: String
    let userID: String
    let appAccountToken: UUID
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var appleSubject: String? = nil
}

protocol CloudCredentialStoring: Sendable {
    func load() throws -> CloudCredentials?
    func save(_ value: CloudCredentials?) throws
}

struct KeychainCloudCredentialStore: CloudCredentialStoring {
    private var lookup: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.rubleuskia.foreignlanguagelearner.cloud", kSecAttrAccount as String: "session-v1"] }
    func load() throws -> CloudCredentials? {
        var query = lookup; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw CloudAPIError(code: "KEYCHAIN_UNAVAILABLE") }
        return try JSONDecoder().decode(CloudCredentials.self, from: bytes)
    }
    func save(_ value: CloudCredentials?) throws {
        guard let value else {
            let status = SecItemDelete(lookup as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudAPIError(code: "KEYCHAIN_UNAVAILABLE") }
            return
        }
        let fields: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(lookup as CFDictionary, fields as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw CloudAPIError(code: "KEYCHAIN_UNAVAILABLE") }
        guard SecItemAdd(lookup.merging(fields) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
            throw CloudAPIError(code: "KEYCHAIN_UNAVAILABLE")
        }
    }
}

struct CloudPKCE: Sendable {
    let verifier: String
    let state: String
    init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CloudAPIError(code: "RANDOM_UNAVAILABLE") }
            return Data(bytes).base64URLEncoded
        }
        verifier = try random(); state = try random()
    }
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded }
    func loginURL(configuration: CloudConfiguration) -> URL {
        var parts = URLComponents(url: configuration.loginURL.appendingPathComponent("oauth2/authorize"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "response_type", value: "code"), .init(name: "client_id", value: configuration.clientID),
            .init(name: "redirect_uri", value: configuration.callbackURL.absoluteString), .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "identity_provider", value: "SignInWithApple"),
            .init(name: "scope", value: "openid email aws.cognito.signin.user.admin paid-cloud/access")]
        return parts.url!
    }
    func code(from callback: URL, configuration: CloudConfiguration) throws -> String {
        guard callback.scheme == configuration.callbackURL.scheme, callback.host == configuration.callbackURL.host,
              callback.path == configuration.callbackURL.path, callback.fragment == nil,
              let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              query.filter({ $0.name == "state" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == state,
              !query.contains(where: { $0.name == "error" }), query.filter({ $0.name == "code" }).count == 1,
              let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw CloudAPIError(code: "INVALID_LOGIN_CALLBACK") }
        return code
    }
}

extension Data {
    fileprivate var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

actor CloudSession {
    static let shared = CloudSession()
    struct Lease: Sendable, Equatable { let userID: String; let generation: Int; let scopeID: String }
    private let configuration: CloudConfiguration?
    private let store: any CloudCredentialStoring
    private let client: any ContextAnalysisHTTPClient
    private var credentials: CloudCredentials?
    private var generation = 0
    private var refreshing: Task<CloudCredentials, Error>?

    init(configuration: CloudConfiguration? = .bundled, store: any CloudCredentialStoring = KeychainCloudCredentialStore(),
         client: any ContextAnalysisHTTPClient = URLSessionContextAnalysisHTTPClient()) {
        self.configuration = configuration; self.store = store; self.client = client
        if let configuration, let saved = try? store.load(), saved.scopeID == configuration.scopeID { credentials = saved }
    }
    func current() -> CloudCredentials? { credentials }
    func lease() throws -> Lease {
        guard let configuration else { throw CloudAPIError(code: "NOT_CONFIGURED") }
        guard let credentials else { throw CloudAPIError(code: "SIGN_IN_REQUIRED") }
        return Lease(userID: credentials.userID, generation: generation, scopeID: configuration.scopeID)
    }
    func validate(_ lease: Lease) throws {
        guard let credentials, credentials.userID == lease.userID, generation == lease.generation,
              credentials.scopeID == lease.scopeID else { throw CloudAPIError(code: "ACCOUNT_CHANGED") }
    }
    static func form(_ fields: [String: String]) -> Data {
        Data(fields.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
        }.joined(separator: "&").utf8)
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }
    func exchange(code: String, verifier: String) async throws {
        guard let configuration else { throw CloudAPIError(code: "NOT_CONFIGURED") }
        let expectedGeneration = generation
        var request = URLRequest(url: configuration.loginURL.appendingPathComponent("oauth2/token"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["grant_type":"authorization_code", "client_id":configuration.clientID,
            "redirect_uri":configuration.callbackURL.absoluteString, "code":code, "code_verifier":verifier])
        let (bytes, response) = try await client.data(for: request)
        guard response.statusCode == 200 else { throw CloudAPIError(code: "SIGN_IN_REQUIRED") }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: bytes)
        guard let refresh = tokens.refresh_token, !refresh.isEmpty, !tokens.access_token.isEmpty,
              tokens.expires_in > 0 else { throw CloudAPIError(code: "INVALID_SESSION") }
        var meRequest = URLRequest(url: configuration.apiURL.appendingPathComponent("v1/me"))
        meRequest.setValue("Bearer \(tokens.access_token)", forHTTPHeaderField: "Authorization")
        let (meData, meResponse) = try await client.data(for: meRequest)
        guard meResponse.statusCode == 200 else { throw Self.error(meData, status: meResponse.statusCode) }
        struct Me: Decodable { let user_id: String; let app_account_token: UUID; let apple_subject: String? }
        let me = try JSONDecoder().decode(Me.self, from: meData)
        guard generation == expectedGeneration else { throw CloudAPIError(code: "ACCOUNT_CHANGED") }
        let next = CloudCredentials(scopeID: configuration.scopeID, userID: me.user_id, appAccountToken: me.app_account_token,
            accessToken: tokens.access_token, refreshToken: refresh, expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expires_in)), appleSubject: me.apple_subject)
        try store.save(next); refreshing?.cancel(); refreshing = nil; credentials = next; generation += 1
    }
    private func accessToken() async throws -> String {
        let lease = try lease()
        guard let configuration, let saved = credentials else { throw CloudAPIError(code: "SIGN_IN_REQUIRED") }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        if let refreshing {
            let next = try await refreshing.value; try validate(lease)
            guard next.userID == lease.userID, next.scopeID == lease.scopeID else { throw CloudAPIError(code: "ACCOUNT_CHANGED") }
            return next.accessToken
        }
        let client = self.client
        let task = Task<CloudCredentials, Error> {
            var request = URLRequest(url: configuration.loginURL.appendingPathComponent("oauth2/token"))
            request.httpMethod = "POST"; request.timeoutInterval = 20
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["grant_type":"refresh_token", "client_id":configuration.clientID, "refresh_token":saved.refreshToken])
            let (bytes, response) = try await client.data(for: request)
            guard response.statusCode == 200 else { throw CloudAPIError(code: "SIGN_IN_REQUIRED") }
            let token = try JSONDecoder().decode(TokenResponse.self, from: bytes)
            guard !token.access_token.isEmpty, token.expires_in > 0 else { throw CloudAPIError(code: "SIGN_IN_REQUIRED") }
            var next = saved; next.accessToken = token.access_token; next.refreshToken = token.refresh_token ?? saved.refreshToken
            next.expiresAt = Date().addingTimeInterval(TimeInterval(token.expires_in))
            return next
        }
        refreshing = task
        do {
            let next = try await task.value; try validate(lease)
            try store.save(next); credentials = next; refreshing = nil
            return next.accessToken
        } catch {
            if generation == lease.generation {
                refreshing = nil
                if (error as? CloudAPIError)?.code == "SIGN_IN_REQUIRED" {
                    try? store.save(nil); credentials = nil; generation += 1
                }
            }
            throw error
        }
    }
    func send(_ path: String, method: String = "GET", body: Data? = nil, idempotencyKey: UUID? = nil,
              expected: Lease? = nil) async throws -> Data {
        let lease = try expected ?? self.lease()
        try validate(lease)
        guard let configuration else { throw CloudAPIError(code: "NOT_CONFIGURED") }
        let token = try await accessToken(); try validate(lease)
        var request = URLRequest(url: configuration.apiURL.appendingPathComponent(path))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey { request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key") }
        let (data, response) = try await client.data(for: request)
        try Task.checkCancellation(); try validate(lease)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                try? store.save(nil); credentials = nil; generation += 1; refreshing?.cancel(); refreshing = nil
            }
            throw Self.error(data, status: response.statusCode)
        }
        return data
    }
    static func error(_ data: Data, status: Int) -> CloudAPIError {
        struct Envelope: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
        return .init(code: (try? JSONDecoder().decode(Envelope.self, from: data).error.code) ?? (status == 401 ? "SIGN_IN_REQUIRED" : "SERVICE_UNAVAILABLE"))
    }
    func signOut() async throws {
        let previous = credentials
        // Always invalidate memory first, even if persistent storage is temporarily unavailable.
        credentials = nil; generation += 1; refreshing?.cancel(); refreshing = nil
        var storageError: (any Error)?
        do { try store.save(nil) } catch { storageError = error }
        if let configuration, let previous {
            var request = URLRequest(url: configuration.loginURL.appendingPathComponent("oauth2/revoke"))
            request.httpMethod = "POST"; request.timeoutInterval = 15
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["client_id":configuration.clientID, "token":previous.refreshToken])
            let (_, response) = try await client.data(for: request)
            guard response.statusCode == 200 else { throw CloudAPIError(code: "SIGN_OUT_REVOCATION_FAILED") }
        }
        if let storageError { throw storageError }
    }
}
