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
    case terra = "gpt-6.1-terra"
    case sol = "gpt-6.1-sol"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mini: "GPT-5 mini"
        case .nano: "GPT-5 nano"
        case .luna: "GPT-6 Luna"
        case .terra: "GPT-6.1 Terra"
        case .sol: "GPT-6.1 Sol"
        }
    }

    var reasoningEffort: String {
        switch self {
        case .mini, .nano: "minimal"
        case .luna: "none"
        case .terra, .sol: "medium"
        }
    }

    var supportedReasoningEfforts: [String] {
        switch self {
        case .mini, .nano: ["minimal", "low", "medium", "high"]
        case .luna, .terra: ["none", "low", "medium", "high", "xhigh", "max"]
        case .sol: ["low", "medium", "high", "xhigh", "max"]
        }
    }

    func resolvedReasoningEffort(_ value: String?) -> String {
        guard let value, supportedReasoningEfforts.contains(value) else { return reasoningEffort }
        return value
    }
}

/// Allow space for reasoning tokens as well as the structured answer.
enum ReasoningRequestBudget {
    static func outputTokens(effort: String, base: Int) -> Int {
        switch effort {
        case "none", "minimal": base
        case "low": max(base, 4096)
        case "medium": max(base, 8192)
        default: max(base, 16384)
        }
    }
    static func timeout(effort: String) -> TimeInterval {
        ["none", "minimal"].contains(effort) ? 30 : 120
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

/// Filter function words by language, never by token length: short content words still matter.
enum ContextAnalysisWords {
    static func wordsToExplain(in text: String, language: String) -> [String] {
        let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? language
        let excluded = functionWords[code] ?? []
        return text.split(whereSeparator: \.isWhitespace).map(String.init).filter { word in
            let normalized = word.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return !normalized.isEmpty && !excluded.contains(normalized)
        }
    }

    private static let functionWords: [String: Set<String>] = [
        "pl": ["a", "aby", "acz", "aczkolwiek", "ale", "albo", "ani", "aż", "bez", "bo", "bowiem",
               "by", "chociaż", "choć", "czy", "czyli", "dla", "do", "gdy", "gdyby", "gdyż", "i",
               "iż", "jak", "jakby", "jeśli", "jeżeli", "ku", "lecz", "lub", "mimo", "między",
               "na", "nad", "o", "obok", "od", "oraz", "oto", "pod", "podczas", "po", "pomimo",
               "ponad", "ponieważ", "poprzez", "poza", "pred", "przed", "przez", "przy", "się",
               "u", "w", "we", "według", "więc", "wobec", "wśród", "z", "za", "zamiast", "ze", "że", "żeby"],
        "en": ["a", "an", "and", "as", "at", "but", "by", "for", "from", "if", "in", "into",
               "nor", "of", "on", "or", "the", "to", "with", "without"],
        "de": ["aber", "als", "am", "an", "auf", "aus", "bei", "das", "der", "die", "ein", "eine",
               "für", "im", "in", "mit", "nach", "oder", "ohne", "und", "von", "vor", "zu", "zum", "zur"],
        "fr": ["à", "au", "aux", "avec", "car", "dans", "de", "des", "du", "en", "et", "la", "le",
               "les", "mais", "ou", "par", "pour", "sans", "sur", "un", "une"],
        "it": ["a", "al", "alla", "con", "da", "dal", "dalla", "di", "del", "della", "e", "ed", "gli", "i", "il", "in", "la", "le", "lo", "ma", "o", "per", "su", "un", "una", "uno"],
        "es": ["a", "al", "con", "de", "del", "el", "en", "la", "las", "los", "o", "para", "pero",
               "por", "sin", "un", "una", "y"]
    ]
}
