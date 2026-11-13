import Foundation

/// An immutable snapshot shared by the request, route label, and backend payload.
struct TranslationRequestSettings: Codable, Hashable, Sendable {
    let mode: CloudProviderMode
    let model: OpenAITranslationModel
    let reasoningEffort: String

    init(mode: CloudProviderMode, model: OpenAITranslationModel, reasoningEffort: String? = nil) {
        self.mode = mode; self.model = model
        self.reasoningEffort = model.resolvedReasoningEffort(reasoningEffort)
    }
    static var current: Self { snapshot(in: .standard) }
    static func snapshot(in defaults: UserDefaults) -> Self {
        let model = ContextAnalysisSettings.selectedModel(in: defaults)
        let mode = CloudProviderMode(rawValue: defaults.string(forKey: CloudProviderMode.key) ?? "") ?? .personalKey
        return Self(mode: mode, model: model,
                    reasoningEffort: ContextAnalysisSettings.reasoningEffort(for: model, in: defaults))
    }
    var routeTitle: String { mode == .personalKey ? "Direct to OpenAI" : "Via cloud backend" }
    var routeIcon: String { mode == .personalKey ? "arrow.up.right" : "cloud" }
}
