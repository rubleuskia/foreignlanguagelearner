import CryptoKit
import SwiftUI

protocol WordExplanationServing: Sendable {
    func explain(_ input: WordExplanationInput) async throws -> WordExplanation
}

actor WordExplanationCache {
    private struct Record: Codable {
        let key: String
        let value: WordExplanation
    }
    private var records: [Record] = []
    private let file: URL?

    init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) {
        file = directory?.appendingPathComponent("WordExplanations-v1.json")
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved.suffix(200).filter { (try? $0.value.validated()) != nil }
        }
    }

    static func key(for input: WordExplanationInput, model: OpenAITranslationModel) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var bytes = try encoder.encode(input)
        bytes.append(contentsOf: "|\(model.rawValue)|\(OpenAIWordExplanationProvider.promptVersion)".utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func value(for key: String) -> WordExplanation? { records.first { $0.key == key }?.value }

    func store(_ value: WordExplanation, for key: String) throws {
        let value = try value.validated()
        records.removeAll { $0.key == key }
        records.append(.init(key: key, value: value))
        records = Array(records.suffix(200))
        // A purgeable, derived cache: disk failure must not hide a successful explanation.
        if let file, let data = try? JSONEncoder().encode(records) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

actor WordExplanationService: WordExplanationServing {
    private let cache = WordExplanationCache()

    func explain(_ input: WordExplanationInput) async throws -> WordExplanation {
        let model = ContextAnalysisSettings.selectedModel()
        let key = try WordExplanationCache.key(for: input, model: model)
        try Task.checkCancellation()
        if let cached = await cache.value(for: key) { return cached }
        guard ContextAnalysisSettings.isCloudAnalysisEnabled(),
              let apiKey = try OpenAIAPIKeyStore.load(), !apiKey.isEmpty else {
            throw ContextAnalysisError.missingConfiguration
        }
        let result = try await OpenAIWordExplanationProvider(apiKey: apiKey, model: model).explain(input)
        try Task.checkCancellation()
        try await cache.store(result, for: key)
        return result
    }
}

private struct WordExplanationServiceKey: EnvironmentKey {
    static let defaultValue: any WordExplanationServing = WordExplanationService()
}

extension EnvironmentValues {
    var wordExplanationService: any WordExplanationServing {
        get { self[WordExplanationServiceKey.self] }
        set { self[WordExplanationServiceKey.self] = newValue }
    }
}
