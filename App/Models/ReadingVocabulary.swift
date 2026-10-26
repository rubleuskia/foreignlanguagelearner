import Foundation
import SwiftData

@Model final class ReadVocabularyWord {
    @Attribute(.unique) var key: String
    var languageCode: String
    var normalizedForm: String
    var firstLearnedAt: Date
    var tokenizerVersion: Int = 1

    init(languageCode: String, normalizedForm: String, firstLearnedAt: Date = .now) {
        self.key = Self.key(languageCode, normalizedForm)
        self.languageCode = languageCode
        self.normalizedForm = normalizedForm
        self.firstLearnedAt = firstLearnedAt
    }

    static func key(_ language: String, _ form: String) -> String {
        // JSON array encoding is unambiguous even when strings contain separators.
        String(data: try! JSONEncoder().encode([language, form]), encoding: .utf8)!
    }
}

struct VocabularyStatistics: Equatable, Sendable {
    let total: Int
    let new: Int
    var known: Int { total - new }
}

struct VocabularyOccurrence: Equatable, Sendable {
    let normalizedForm: String
    let rangeUTF16: NSRange
}
