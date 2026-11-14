import CryptoKit
import Foundation
import SwiftData

@Model final class SentenceTranslation {
    @Attribute(.unique) var key: String
    var sourceText: String
    var sourceLanguage: String
    var targetLanguage: String
    var translation: String
    var createdAt: Date

    init(text: String, sourceLanguage: String, targetLanguage: String, translation: String) {
        key = Self.key(text: text, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        sourceText = text
        self.sourceLanguage = SourceLanguage.canonical(sourceLanguage)
        self.targetLanguage = SourceLanguage.canonical(targetLanguage)
        self.translation = translation
        createdAt = .now
    }

    static func key(text: String, sourceLanguage: String, targetLanguage: String) -> String {
        // Delimit unambiguously; do not normalize whitespace or punctuation.
        let parts = [SourceLanguage.canonical(sourceLanguage), SourceLanguage.canonical(targetLanguage),
                     text.lowercased(with: Locale(identifier: "en_US_POSIX"))]
        return digest(String(data: try! JSONEncoder().encode(parts), encoding: .utf8)!)
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Local source anchors deliberately do not depend on pagination or DictionaryEntry.
@Model final class BookSentenceTranslation {
    @Attribute(.unique) var key: String
    var itemID: UUID
    var scope: String
    var documentDigest: String
    var location: Int
    var length: Int
    var translationKey: String

    init(itemID: UUID, scope: String, documentDigest: String, range: NSRange, translationKey: String) {
        self.itemID = itemID; self.scope = scope; self.documentDigest = documentDigest
        location = range.location; length = range.length; self.translationKey = translationKey
        key = SentenceTranslation.digest("\(itemID)|\(scope)|\(documentDigest)|\(range.location)|\(range.length)|\(translationKey)")
    }
}

struct TranslatedBookSentence: Equatable {
    let range: NSRange
    let text: String
    let translation: String
}
