import Foundation
import Security

struct OperatorCredentials: Codable, Sendable, Equatable {
    let clientID: String
    let apiURL: URL
    let username: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

protocol OperatorCredentialStoring: Sendable {
    func load() throws -> OperatorCredentials?
    func save(_ value: OperatorCredentials?) throws
}

struct KeychainOperatorCredentialStore: OperatorCredentialStoring {
    private var lookup: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.rubleuskia.foreignlanguagelearner.operator",
        kSecAttrAccount as String: "operator-session-v1"] }
    func load() throws -> OperatorCredentials? {
        var query = lookup; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = result as? Data else { throw OperatorSessionError.storage }
        return try JSONDecoder().decode(OperatorCredentials.self, from: bytes)
    }
    func save(_ value: OperatorCredentials?) throws {
        guard let value else {
            let status = SecItemDelete(lookup as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw OperatorSessionError.storage }
            try OperatorAccessTokenStore.delete()
            return
        }
        let fields: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(lookup as CFDictionary, fields as CFDictionary)
        if status != errSecSuccess {
            guard status == errSecItemNotFound,
                  SecItemAdd(lookup.merging(fields) { _, new in new } as CFDictionary, nil) == errSecSuccess
            else { throw OperatorSessionError.storage }
        }
        try OperatorAccessTokenStore.delete()
    }
}

enum OperatorSessionError: Error, LocalizedError {
    case signInRequired, denied, temporaryPassword, unavailable, storage, changed
    var errorDescription: String? {
        let message = switch self {
        case .signInRequired: "Sign in to the built-in library in Settings."
        case .denied: "Incorrect library username or password, or access is denied."
        case .temporaryPassword: "Set a permanent password for this user in Cognito, then sign in again."
        case .unavailable: "Library sign-in is temporarily unavailable. Please try again."
        case .storage: "Could not access the library session in Keychain."
        case .changed: "The library session changed. Refresh the catalog."
        }
        return AppLanguage.text(message)
    }
}

/// Private operator session, separate from Apple/subscription credentials and personal OpenAI keys.
actor OperatorSession {
    static let shared = OperatorSession()
    struct Lease: Sendable { let token: String; let generation: Int }
    static let clientID = (Bundle.main.object(forInfoDictionaryKey: "BookLibraryClientID") as? String)
        ?? "6lsol40jf4jq189v89ar5o73cu"
    private let clientID: String
    private let apiURL: URL
    private let store: any OperatorCredentialStoring
    private let client: any ContextAnalysisHTTPClient
    private var generation = 0
    private var refreshing: Task<OperatorCredentials, Error>?
    private var refreshID: UUID?

    init(clientID: String = OperatorSession.clientID, apiURL: URL = BuiltinLibraryService.baseURL,
         store: any OperatorCredentialStoring = KeychainOperatorCredentialStore(),
         client: any ContextAnalysisHTTPClient = URLSessionContextAnalysisHTTPClient(
            session: URLSession(configuration: .ephemeral))) {
        self.clientID = clientID; self.apiURL = apiURL; self.store = store; self.client = client
    }
    func username() throws -> String? { try saved()?.username }
    private func saved() throws -> OperatorCredentials? {
        guard let value = try store.load(), value.clientID == clientID, value.apiURL == apiURL else { return nil }
        return value
    }
    private func clear() throws {
        generation += 1; refreshing?.cancel(); refreshing = nil; refreshID = nil
        try store.save(nil)
    }
    func signIn(username: String, password: String) async throws {
        try clear()
        let expected = generation
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else { throw OperatorSessionError.denied }
        let credentials = try await Self.authenticate(client: client, clientID: clientID, apiURL: apiURL,
            username: name, parameters: ["USERNAME": name, "PASSWORD": password], refreshToken: nil)
        guard generation == expected else { throw OperatorSessionError.changed }
        // Confirm operator authority through the backend, not just successful pool authentication.
        var request = URLRequest(url: apiURL.appending(path: "v1/me"))
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await client.data(for: request)
        guard generation == expected else { throw OperatorSessionError.changed }
        let profile = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard response.statusCode == 200, profile?["role"] as? String == "operator" else {
            throw OperatorSessionError.denied
        }
        try store.save(credentials)
    }
    func signOut() async throws {
        let previous = try saved()
        try clear() // A late refresh cannot restore the signed-out session, even if revocation fails.
        if let previous {
            let (data, response) = try await client.data(for: Self.cognitoRequest("RevokeToken",
                body: ["ClientId": clientID, "Token": previous.refreshToken]))
            guard response.statusCode == 200 else { throw Self.error(data, status: response.statusCode) }
        }
    }
    func validate(_ lease: Lease) throws {
        guard generation == lease.generation else { throw OperatorSessionError.changed }
    }
    func lease(rejected: Lease? = nil) async throws -> Lease {
        if let rejected { try validate(rejected) }
        guard let saved = try saved() else { throw OperatorSessionError.signInRequired }
        if saved.expiresAt.timeIntervalSinceNow > 60, saved.accessToken != rejected?.token {
            return Lease(token: saved.accessToken, generation: generation)
        }
        let expected = generation
        let task: Task<OperatorCredentials, Error>
        let taskID: UUID
        if let refreshing, let refreshID { task = refreshing; taskID = refreshID }
        else {
            let client = client, clientID = clientID, apiURL = apiURL
            task = Task {
                try await Self.authenticate(client: client, clientID: clientID, apiURL: apiURL,
                    username: saved.username, parameters: ["REFRESH_TOKEN": saved.refreshToken],
                    refreshToken: saved.refreshToken)
            }
            taskID = UUID(); refreshing = task; refreshID = taskID
        }
        do {
            let next = try await task.value
            guard generation == expected else { throw OperatorSessionError.changed }
            if refreshID == taskID {
                try store.save(next); refreshing = nil; refreshID = nil
            }
            guard let current = try self.saved() else { throw OperatorSessionError.signInRequired }
            return Lease(token: current.accessToken, generation: generation)
        } catch {
            if generation == expected, refreshID == taskID {
                refreshing = nil; refreshID = nil
                if case OperatorSessionError.signInRequired = error { try clear() }
            }
            throw error
        }
    }
    private static func cognitoRequest(_ operation: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://cognito-idp.eu-north-1.amazonaws.com/")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.\(operation)", forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    private static func error(_ data: Data, status: Int) -> OperatorSessionError {
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let type = (body?["__type"] as? String)?.components(separatedBy: "#").last
        if status == 400, ["NotAuthorizedException", "UserNotFoundException"].contains(type ?? "") {
            return .signInRequired
        }
        return .unavailable
    }
    private static func authenticate(client: any ContextAnalysisHTTPClient, clientID: String, apiURL: URL,
        username: String, parameters: [String: String], refreshToken: String?) async throws -> OperatorCredentials {
        let (data, response) = try await client.data(for: cognitoRequest("InitiateAuth", body: [
            "ClientId": clientID, "AuthFlow": refreshToken == nil ? "USER_PASSWORD_AUTH" : "REFRESH_TOKEN_AUTH",
            "AuthParameters": parameters]))
        guard response.statusCode == 200 else {
            let failure = error(data, status: response.statusCode)
            if refreshToken == nil, case .signInRequired = failure { throw OperatorSessionError.denied }
            throw failure
        }
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if body?["ChallengeName"] as? String == "NEW_PASSWORD_REQUIRED" { throw OperatorSessionError.temporaryPassword }
        guard let result = body?["AuthenticationResult"] as? [String: Any],
              let access = result["AccessToken"] as? String, !access.isEmpty,
              let refresh = result["RefreshToken"] as? String ?? refreshToken, !refresh.isEmpty,
              let expires = result["ExpiresIn"] as? Double, expires > 0 else { throw OperatorSessionError.unavailable }
        return OperatorCredentials(clientID: clientID, apiURL: apiURL, username: username,
            accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires))
    }
}
