import Foundation

enum ContextAnalysisSettings {
    static let modelKey = "contextAnalysis.openAIModel"
    static let cloudAnalysisEnabledKey = "contextAnalysis.cloudEnabled"
    static let promptOverrideKey = "contextAnalysis.promptOverride"
    static let maximumPromptUTF16 = 8_000

    static func selectedModel(in defaults: UserDefaults = .standard) -> OpenAITranslationModel {
        guard let rawValue = defaults.string(forKey: modelKey),
              let model = OpenAITranslationModel(rawValue: rawValue) else {
            return .mini
        }
        return model
    }

    static func setSelectedModel(_ model: OpenAITranslationModel,
                                 in defaults: UserDefaults = .standard) {
        defaults.set(model.rawValue, forKey: modelKey)
    }

    static func isCloudAnalysisEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: cloudAnalysisEnabledKey)
    }

    static func setCloudAnalysisEnabled(_ enabled: Bool,
                                        in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: cloudAnalysisEnabledKey)
    }

    static func prompt(in defaults: UserDefaults = .standard) -> String {
        guard let override = promptOverride(in: defaults) else {
            return OpenAIContextAnalysisProvider.defaultPrompt
        }
        return override
    }

    static func promptOverride(in defaults: UserDefaults = .standard) -> String? {
        guard let value = defaults.string(forKey: promptOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf16.count <= maximumPromptUTF16 else { return nil }
        return value
    }

    static func setPrompt(_ value: String, in defaults: UserDefaults = .standard) throws {
        let prompt = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.utf16.count <= maximumPromptUTF16 else {
            throw ContextAnalysisSettingsError.invalidPrompt
        }
        if prompt == OpenAIContextAnalysisProvider.defaultPrompt {
            defaults.removeObject(forKey: promptOverrideKey)
        } else {
            defaults.set(prompt, forKey: promptOverrideKey)
        }
    }

    static func resetPrompt(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: promptOverrideKey)
    }
}

enum ContextAnalysisSettingsError: Error, Equatable {
    case invalidPrompt
}
