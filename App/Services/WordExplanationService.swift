import CryptoKit
import SwiftUI

protocol WordExplanationServing: Sendable {
    func explain(_ input: WordExplanationInput) async throws -> WordExplanation
}

actor WordExplanationCache {
    struct Record: Codable, Sendable {
        let key: String
        let value: WordExplanation
    }
    private var records: [Record] = []
    private let file: URL?

    static var defaultFile: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WordExplanations-v1.json")
    }

    nonisolated static func backupRecords(at file: URL?) throws -> [Record] {
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return [] }
        return Array(try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)).suffix(200)).filter {
            (try? $0.value.validated()) != nil
        }
    }

    nonisolated static func restoreRecords(_ records: [Record], at file: URL?) throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: file, options: .atomic)
    }

    init(directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) {
        file = directory?.appendingPathComponent("WordExplanations-v1.json")
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved.suffix(200).filter { (try? $0.value.validated()) != nil }
        }
    }

    static func key(for input: WordExplanationInput, model: OpenAITranslationModel,
                    prompt: String = OpenAIWordExplanationProvider.defaultPrompt, reasoningEffort: String? = nil) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var bytes = try encoder.encode(input)
        bytes.append(contentsOf: "|\(model.rawValue)|\(OpenAIWordExplanationProvider.promptVersion)|\(prompt)|\(model.resolvedReasoningEffort(reasoningEffort))".utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func value(for key: String) -> WordExplanation? {
        // Restore can replace the file while the app's service actor is already alive.
        if let file, let saved = try? Self.backupRecords(at: file) { records = saved }
        return records.first { $0.key == key }?.value
    }

    func store(_ value: WordExplanation, for key: String) throws {
        if let file, let saved = try? Self.backupRecords(at: file) { records = saved }
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
        let prompt = ContextAnalysisSettings.wordExplanationPrompt()
        let effort = ContextAnalysisSettings.reasoningEffort(for: model)
        let key = try WordExplanationCache.key(for: input, model: model, prompt: prompt, reasoningEffort: effort)
        try Task.checkCancellation()
        if let cached = await cache.value(for: key) { return cached }
        guard ContextAnalysisSettings.isCloudAnalysisEnabled(),
              let apiKey = try OpenAIAPIKeyStore.load(), !apiKey.isEmpty else {
            throw ContextAnalysisError.missingConfiguration
        }
        let result = try await OpenAIWordExplanationProvider(apiKey: apiKey, model: model, reasoningEffort: effort, prompt: prompt).explain(input)
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
