import Foundation

enum ContextAnalysisSubject: Equatable, Sendable {
    case dictionaryEntry(UUID)
    case preview(UUID)
}

struct ContextAnalysisRequest: Equatable, Sendable {
    let requestID: UUID
    let subject: ContextAnalysisSubject
    let revision: Int
    let selectedText: String
    let contextFragment: String
    let selectionLocationUTF16: Int
    let selectionLengthUTF16: Int
    let contextWasReduced: Bool
    let sourceLanguage: String
    let targetLanguage: String
    let promptVersion: String
}

struct ContextualPhraseResult: Equatable, Sendable {
    let directTranslation: String
    let contextExplanation: String
}

protocol ContextAnalysisProvider: Sendable {
    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult
}

enum ContextAnalysisAvailabilityReason: String, Codable, Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case assetsUnavailable
    case unsupportedLanguageOrLocale
    case unknown
}

enum ContextAnalysisAvailability: Equatable, Sendable {
    case available
    case unavailable(ContextAnalysisAvailabilityReason)
}

enum ContextAnalysisStatus: String, Codable, Equatable, Sendable {
    case idle
    case queued
    case analyzing
    case ready
    case unavailable
    case failed
}

protocol ContextAnalysisAvailabilityChecking: Sendable {
    func availability(sourceLanguage: String, targetLanguage: String) async -> ContextAnalysisAvailability
}

enum ContextAnalysisError: String, Codable, Error, Equatable, Sendable {
    case invalidContext
    case invalidLanguage
    case selectionTooLong
    case inputTooLarge
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case assetsUnavailable
    case unsupportedLanguageOrLocale
    case guardrailViolation
    case refusal
    case rateLimited
    case busy
    case concurrentRequests
    case unsupportedGuide
    case decodingFailure
    case invalidOutput
    case persistence
    case unknown
}

extension ContextAnalysisError {
    var isUnavailable: Bool {
        switch self {
        case .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
             .assetsUnavailable, .unsupportedLanguageOrLocale:
            true
        default:
            false
        }
    }

    var userMessage: String {
        switch self {
        case .invalidContext: "The saved source context is missing or no longer matches this phrase."
        case .invalidLanguage: "The source or target language code is invalid."
        case .selectionTooLong: "Select a shorter phrase (up to 256 UTF-16 units)."
        case .inputTooLarge: "The context is too large for the on-device model."
        case .deviceNotEligible: "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled: "Enable Apple Intelligence in Settings to analyze this phrase."
        case .modelNotReady: "The on-device model is not ready yet. Check availability and try again."
        case .assetsUnavailable: "Required on-device model resources are unavailable."
        case .unsupportedLanguageOrLocale: "The on-device model does not support this language pair."
        case .guardrailViolation: "The on-device model declined this source text for safety reasons."
        case .refusal: "The on-device model declined this request."
        case .rateLimited: "The on-device model is temporarily rate limited. Try again in a few seconds."
        case .busy: "Another context analysis is already queued. Try again when it finishes."
        case .concurrentRequests, .unsupportedGuide: "Context analysis encountered an application configuration error."
        case .decodingFailure, .invalidOutput: "The on-device model returned an unusable response."
        case .persistence: "The analysis could not be saved. Your previous result is unchanged."
        case .unknown: "Context analysis failed for an unknown reason."
        }
    }
}

enum ContextAnalysisLimits {
    static let maximumSelectionUTF16 = 256
    static let maximumContextUTF16 = 1_400
    static let retryContextUTF16 = 700
    static let maximumDirectTranslationUTF16 = 512
    static let maximumContextExplanationUTF16 = 2_000
    static let maximumResponseTokens = 512
    static let tokenReserve = 256
}

enum ContextAnalysisText {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
