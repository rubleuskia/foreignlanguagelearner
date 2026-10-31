import XCTest
@testable import ForeignLanguageLearner

final class ReasoningSettingsTests: XCTestCase {
    func testModelCompatibilityAndDefaults() {
        XCTAssertEqual(OpenAITranslationModel.mini.displayName, "GPT-5 mini")
        XCTAssertEqual(OpenAITranslationModel.nano.displayName, "GPT-5 nano")
        XCTAssertEqual(OpenAITranslationModel.sol.resolvedReasoningEffort("none"), "medium")
        XCTAssertEqual(OpenAITranslationModel.nano.resolvedReasoningEffort("max"), "minimal")
        XCTAssertEqual(OpenAITranslationModel.terra.resolvedReasoningEffort("none"), "none")
        XCTAssertEqual(OpenAITranslationModel.luna.resolvedReasoningEffort(nil), "none")
        for model in OpenAITranslationModel.allCases {
            XCTAssertTrue(model.supportedReasoningEfforts.contains(model.reasoningEffort))
            for effort in model.supportedReasoningEfforts {
                XCTAssertEqual(model.resolvedReasoningEffort(effort), effort)
            }
        }
    }

    func testSettingsBackupRoundTripAndLegacyFallback() throws {
        let suite = "ReasoningSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ContextAnalysisSettings.setSelectedModel(.sol, in: defaults)
        defaults.set("high", forKey: ContextAnalysisSettings.reasoningEffortKey)
        let settings = LibraryBackupDocument.Settings(defaults: defaults)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(LibraryBackupDocument.Settings.self, from: data)
        defaults.removeObject(forKey: ContextAnalysisSettings.reasoningEffortKey)
        try decoded.apply(to: defaults)
        XCTAssertEqual(ContextAnalysisSettings.selectedModel(in: defaults), .sol)
        XCTAssertEqual(ContextAnalysisSettings.reasoningEffort(for: .sol, in: defaults), "high")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "reasoningEffort")
        let restored = try JSONDecoder().decode(LibraryBackupDocument.Settings.self, from: JSONSerialization.data(withJSONObject: legacy))
        try restored.apply(to: defaults)
        XCTAssertEqual(ContextAnalysisSettings.reasoningEffort(for: .sol, in: defaults), "medium")
        defaults.set("none", forKey: ContextAnalysisSettings.reasoningEffortKey)
        XCTAssertEqual(ContextAnalysisSettings.reasoningEffort(for: .sol, in: defaults), "medium")
        XCTAssertEqual(ContextAnalysisSettings.reasoningEffort(for: .terra, in: defaults), "none")
    }
}
