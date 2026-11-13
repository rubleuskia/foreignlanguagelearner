import XCTest
@testable import ForeignLanguageLearner

final class TranslationRequestSettingsTests: XCTestCase {
    private func request() -> ContextAnalysisRequest {
        .init(requestID: UUID(), subject: .preview(UUID()), revision: 1, selectedText: "dom",
              contextFragment: "To jest dom.", selectionLocationUTF16: 8, selectionLengthUTF16: 3,
              contextWasReduced: false, sourceLanguage: "pl", targetLanguage: "ru", promptVersion: "test")
    }
    private func body(_ payload: CloudTranslationPayload) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
    }
    func testContextAndWordPayloadsCarryExactModelAndReasoning() throws {
        for model in OpenAITranslationModel.allCases {
            for effort in model.supportedReasoningEfforts {
                let settings = TranslationRequestSettings(mode: .subscription, model: model, reasoningEffort: effort)
                var input = WordExplanationInput(sourceWord: "dom", lemma: "dom", context: "To jest dom.",
                    selectionLocationUTF16: 8, selectionLengthUTF16: 3, sourceLanguage: "pl", targetLanguage: "ru")
                input.execution = settings
                var request = request(); request.execution = settings
                for payload in [CloudTranslationPayload(request), CloudTranslationPayload(input)] {
                    let json = try body(payload)
                    XCTAssertEqual(json["model"] as? String, model.rawValue)
                    XCTAssertEqual(json["reasoning_effort"] as? String, effort)
                    XCTAssertNil(json["execution"])
                    XCTAssertNil(json["max_output_tokens"])
                }
            }
        }
    }
    func testSnapshotRetainsRouteAndSettingsAfterPreferencesChange() throws {
        let suite = "TranslationRequestSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(CloudProviderMode.subscription.rawValue, forKey: CloudProviderMode.key)
        defaults.set(OpenAITranslationModel.sol.rawValue, forKey: ContextAnalysisSettings.modelKey)
        defaults.set("high", forKey: ContextAnalysisSettings.reasoningEffortKey)
        let snapshot = TranslationRequestSettings.snapshot(in: defaults)
        defaults.set(CloudProviderMode.personalKey.rawValue, forKey: CloudProviderMode.key)
        defaults.set("low", forKey: ContextAnalysisSettings.reasoningEffortKey)
        XCTAssertEqual(snapshot.routeTitle, "Via cloud backend")
        XCTAssertEqual(snapshot.model, .sol); XCTAssertEqual(snapshot.reasoningEffort, "high")
        XCTAssertEqual(TranslationRequestSettings.snapshot(in: defaults).routeTitle, "Direct to OpenAI")
        XCTAssertEqual(TranslationRequestSettings.snapshot(in: defaults).reasoningEffort, "low")
    }
    func testLegacyUnknownIntentBlocksNewPaidIntentUntilExplicitRecovery() async throws {
        let ledger = CloudRequestLedger(file: nil)
        let lease = CloudSession.Lease(userID: "operator", generation: 0, scopeID: "test")
        let old = try await ledger.entry(lease, fingerprint: "old-format", kind: "context")
        try await ledger.mark(old, state: "outcome_unknown", policyVersion: "old-policy")
        do {
            _ = try await ledger.entry(lease, fingerprint: "new-format", kind: "context", legacyFingerprint: "old-format")
            XCTFail("Must not create a fresh paid request after a format upgrade")
        } catch { XCTAssertEqual(error as? ContextAnalysisError, .cloudOutcomeUnknown) }
        let entries = try await ledger.list(lease)
        XCTAssertEqual(entries.count, 1)
    }
    func testChangingSettingsChangesEncodedIdempotencyInput() throws {
        let first = TranslationRequestSettings(mode: .subscription, model: .mini, reasoningEffort: "minimal")
        let second = TranslationRequestSettings(mode: .subscription, model: .mini, reasoningEffort: "high")
        let third = TranslationRequestSettings(mode: .subscription, model: .nano, reasoningEffort: "minimal")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try [first, second, third].map { try encoder.encode(CloudTranslationPayload(request(), settings: $0)) }
        XCTAssertNotEqual(bytes[0], bytes[1]); XCTAssertNotEqual(bytes[0], bytes[2])
        // A settings snapshot wins over changed defaults when building the actual payload.
        var input = request(); input.execution = second
        XCTAssertEqual(try body(CloudTranslationPayload(input))["reasoning_effort"] as? String, "high")
    }
}
