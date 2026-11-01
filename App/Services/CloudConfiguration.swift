import Foundation
import CryptoKit

/// Bundled configuration only. A normal build contains no endpoint and cannot spend cloud credit.
struct CloudConfiguration: Sendable, Equatable {
    let apiURL: URL
    let loginURL: URL
    let clientID: String
    let callbackURL: URL
    let environment: String
    let productIDs: [String]
    let privacyURL: URL
    let termsURL: URL
    let supportURL: URL

    static var bundled: Self? {
        if let direct = try? Self(info: Bundle.main.infoDictionary ?? [:]) { return direct }
        guard let url = Bundle.main.url(forResource: "CloudConfiguration", withExtension: "plist"),
              let bytes = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { return nil }
        return try? Self(info: info)
    }
    init(info: [String: Any]) throws {
        func https(_ key: String) throws -> URL {
            guard let raw = info[key] as? String, let url = URL(string: raw), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw CloudAPIError(code: "NOT_CONFIGURED")
            }
            return url
        }
        apiURL = try https("CloudAPIBaseURL"); loginURL = try https("CloudCognitoDomain")
        privacyURL = try https("CloudPrivacyURL"); termsURL = try https("CloudTermsURL"); supportURL = try https("CloudSupportURL")
        guard let client = info["CloudClientID"] as? String, !client.isEmpty,
              let callback = info["CloudCallbackURL"] as? String, let url = URL(string: callback),
              url.scheme == "fll", url.host == "auth", url.path.isEmpty, url.query == nil, url.fragment == nil,
              let stage = info["CloudEnvironment"] as? String, ["Sandbox", "Production"].contains(stage),
              let products = info["CloudProducts"] as? [String], !products.isEmpty, products.allSatisfy({ !$0.isEmpty }) else {
            throw CloudAPIError(code: "NOT_CONFIGURED")
        }
        clientID = client; callbackURL = url; environment = stage; productIDs = products
    }
    var scopeID: String { SHA256.hash(data: Data("\(apiURL)|\(loginURL)|\(clientID)|\(environment)".utf8)).map { String(format: "%02x", $0) }.joined() }
}

enum CloudProviderMode: String, CaseIterable, Identifiable {
    case personalKey, subscription
    static let key = "cloud.providerMode.v1"
    var id: String { rawValue }
    static var current: Self { Self(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .personalKey }
}

struct CloudAPIError: Error, LocalizedError, Sendable {
    let code: String
    var errorDescription: String? {
        let key = switch code {
        case "PURCHASES_UNAVAILABLE": "New subscriptions are currently unavailable. You can still restore purchases and recover existing results."
        case "NOT_CONFIGURED": "Cloud subscriptions are not configured in this build."
        case "APPLE_IDENTITY_UNAVAILABLE": "Cloud sign-in could not be verified. Sign in again with the same Apple account or contact support."
        case "SIGN_IN_REQUIRED", "UNAUTHORIZED", "SESSION_REVOKED": "Sign in to use your subscription."
        case "ACCOUNT_CHANGED": "The cloud account changed. Open the request again after signing in."
        case "APPLE_ACCOUNT_CONFLICT", "INVALID_APPLE_IDENTITY", "APPLE_REAUTH_REQUIRED", "APPLE_ACCOUNT_NOT_LINKED": "Confirm deletion with the Apple account used for cloud sign-in. If accounts do not match, contact support."
        case "SUBSCRIPTION_REQUIRED": "An active subscription is required. Restore purchases or check your account."
        case "PURCHASE_ACCOUNT_CONFLICT", "ACCOUNT_BINDING_REQUIRED": "This purchase belongs to another app account. Sign in to the original account or contact support."
        case "ADMISSION_LIMIT": "Your allowance or the service capacity is currently unavailable. Check your subscription and try later."
        case "OUTCOME_UNKNOWN": "The provider may have processed this request. It will not be sent again automatically. Your allowance was released."
        case "RESULT_EXPIRED", "REQUEST_EXPIRED": "This cloud result has expired. Select the text again to make a new request."
        case "REQUEST_FAILED": "The cloud request failed. Your allowance was released."
        case "CANCELLED": "The request was cancelled before processing."
        case "PURCHASE_PENDING": "Apple is waiting for purchase approval. You do not need to buy again."
        case "ACTIVATION_PENDING": "Your purchase is waiting for activation. Retry activation or restore purchases; do not buy again."
        default: "The cloud service is temporarily unavailable. Try again later."
        }
        return AppLanguage.text(key)
    }
    var analysisError: ContextAnalysisError {
        switch code {
        case "NOT_CONFIGURED": .missingConfiguration
        case "SIGN_IN_REQUIRED", "UNAUTHORIZED", "SESSION_REVOKED", "APPLE_IDENTITY_UNAVAILABLE": .unauthorized
        case "ACCOUNT_CHANGED": .cancelled
        case "INVALID_LANGUAGE": .invalidLanguage
        case "INVALID_SELECTION", "INVALID_TEXT", "INVALID_UNICODE", "INVALID_REQUEST": .invalidContext
        case "ACCOUNT_DISABLED": .forbidden
        case "SUBSCRIPTION_REQUIRED": .subscriptionRequired
        case "ADMISSION_LIMIT": .cloudAllowanceUnavailable
        case "OUTCOME_UNKNOWN": .cloudOutcomeUnknown
        case "RESULT_EXPIRED", "REQUEST_EXPIRED": .cloudResultExpired
        case "CANCELLED": .cancelled
        default: .serverError
        }
    }
}
