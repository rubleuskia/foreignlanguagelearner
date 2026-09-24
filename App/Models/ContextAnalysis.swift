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
    let diagnostics: ContextAnalysisDiagnostics?

    init(directTranslation: String, contextExplanation: String,
         diagnostics: ContextAnalysisDiagnostics? = nil) {
        self.directTranslation = directTranslation
        self.contextExplanation = contextExplanation
        self.diagnostics = diagnostics
    }
}

protocol ContextAnalysisProvider: Sendable {
    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult
}

struct ContextAnalysisDiagnostics: Equatable, Sendable {
    let model: OpenAITranslationModel
    let providerRequestID: String?
}

enum OpenAITranslationModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case mini = "gpt-5-mini"
    case nano = "gpt-5-nano"
    case luna = "gpt-6-luna"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mini: "Mini"
        case .nano: "Nano"
        case .luna: "Luna"
        }
    }

    var reasoningEffort: String {
        switch self {
        case .mini, .nano: "minimal"
        case .luna: "none"
        }
    }
}

enum ContextAnalysisStatus: String, Codable, Equatable, Sendable {
    case idle
    case queued
    case analyzing
    case ready
    case unavailable
    case failed
}

enum ContextAnalysisError: String, Codable, Error, Equatable, Sendable {
    case invalidContext
    case invalidLanguage
    case inputTooLarge
    case missingConfiguration
    case unauthorized
    case forbidden
    case modelUnavailable
    case rateLimited
    case networkUnavailable
    case timeout
    case serverError
    case cancelled
    case busy
    case decodingFailure
    case invalidOutput
    case persistence
    case unknown
}

extension ContextAnalysisError {
    var userMessage: String {
        switch self {
        case .invalidContext: "The saved source context is missing or no longer matches this phrase."
        case .invalidLanguage: "The source or target language code is invalid."
        case .inputTooLarge: "Select a shorter phrase or use less surrounding context."
        case .missingConfiguration: "Contextual translation is not configured."
        case .unauthorized, .forbidden: "Contextual translation authorization failed."
        case .modelUnavailable: "The selected model is unavailable. Choose another model in Settings."
        case .rateLimited: "Contextual translation is temporarily rate limited. Try again later."
        case .networkUnavailable: "A network connection is required for contextual translation."
        case .timeout: "Contextual translation timed out. Try again."
        case .serverError: "The contextual translation service is temporarily unavailable."
        case .cancelled: "Contextual translation was cancelled."
        case .busy: "Another context analysis is already queued. Try again when it finishes."
        case .decodingFailure, .invalidOutput: "The service returned an unusable response."
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
    static let maximumResponseTokens = 1_024
    static let tokenReserve = 256
}

enum ContextAnalysisText {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
