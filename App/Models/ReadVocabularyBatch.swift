import Foundation
import SwiftData

/// Append-only knowledge learned in one operation. Bounded blobs avoid one managed object per
/// word during completion while preserving the same atomic save as the reading flags.
@Model final class ReadVocabularyBatch {
    @Attribute(.unique) var id: UUID
    var languageCode: String
    var formsData: Data
    var firstLearnedAt: Date
    var tokenizerVersion: Int = 1

    init(language: String, formsData: Data, firstLearnedAt: Date = .now) {
        id = UUID(); languageCode = language; self.formsData = formsData
        self.firstLearnedAt = firstLearnedAt
    }
}

enum ReadingKnowledge {
    @MainActor static func loadForms(context: ModelContext) async throws -> [String: Set<String>] {
        // Flush the sole writer before opening a background read-only context.
        try context.save()
        let container = context.container
        let task = Task.detached {
            let reader = ModelContext(container)
            reader.autosaveEnabled = false
            return try forms(context: reader)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func forms(context: ModelContext) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for word in try context.fetch(FetchDescriptor<ReadVocabularyWord>()) {
            try Task.checkCancellation()
            result[word.languageCode, default: []].insert(word.normalizedForm)
        }
        for batch in try context.fetch(FetchDescriptor<ReadVocabularyBatch>()) {
            try Task.checkCancellation()
            guard batch.tokenizerVersion == VocabularyTokenizer.version else { throw ReadingVocabularyError.changed }
            result[batch.languageCode, default: []].formUnion(try JSONDecoder().decode([String].self, from: batch.formsData))
        }
        return result
    }

    /// Compatibility boundary for portable v3 exports and restore previews. Never used by playback
    /// or completion: those paths operate on bounded blobs and the store's hash-set snapshot.
    static func words(context: ModelContext) throws -> [ReadVocabularyWord] {
        var result = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<ReadVocabularyWord>()).map { ($0.key, $0) })
        for batch in try context.fetch(FetchDescriptor<ReadVocabularyBatch>()) {
            try Task.checkCancellation()
            guard batch.tokenizerVersion == VocabularyTokenizer.version else { throw ReadingVocabularyError.changed }
            for form in try JSONDecoder().decode([String].self, from: batch.formsData) {
                let key = ReadVocabularyWord.key(batch.languageCode, form)
                if let existing = result[key], existing.firstLearnedAt <= batch.firstLearnedAt { continue }
                // Detached DTO-compatible model; never mutate persisted rows just to export.
                result[key] = ReadVocabularyWord(languageCode: batch.languageCode, normalizedForm: form, firstLearnedAt: batch.firstLearnedAt)
            }
        }
        return Array(result.values)
    }

    nonisolated static func encode(_ forms: Set<String>) throws -> [Data] {
        let values = Array(forms)
        return try stride(from: 0, to: values.count, by: 2048).map {
            try JSONEncoder().encode(Array(values[$0..<min($0 + 2048, values.count)]))
        }
    }

    static func insert(_ data: [Data], language: String, date: Date = .now, context: ModelContext) {
        for blob in data { context.insert(ReadVocabularyBatch(language: language, formsData: blob, firstLearnedAt: date)) }
    }
}
