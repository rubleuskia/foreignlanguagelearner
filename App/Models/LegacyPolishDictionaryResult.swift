import Foundation

// Retained for SwiftData and v2/v3 dictionary backup compatibility. No live lookup remains.
struct PolishDictionaryResult: Codable, Equatable, Sendable {
    var requestedWord: String
    var headword: String
    var resolvedFromForm: String? = nil
    var partOfSpeech: String?
    var meanings: [PolishDictionaryMeaning]
    var sourceURL: String
    var revisionID: Int?
    var fetchedAt: Date
    var formOfLemma: String? = nil
}

struct PolishDictionaryMeaning: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var definition: String
    var examples: [String]
    var usageLabels: [String]
}

