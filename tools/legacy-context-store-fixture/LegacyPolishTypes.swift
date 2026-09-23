import Foundation

// Minimal copies of the Codable value types referenced by the current (pre-migration)
// DictionaryEntry schema. The @Model classes themselves are compiled directly from
// App/Models/LibraryModels.swift by generate.sh.
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
