import Foundation
import CryptoKit

struct ExamAssessmentResult: Codable, Sendable, Equatable {
    let scoreUnits: Int
    let rationale: String
    enum CodingKeys: String, CodingKey { case scoreUnits = "score_units", rationale }
}

/// Uses the translation provider settings, key store, HTTP client and cloud request ledger.
actor ExamAssessmentService {
    private let api: ExamAPIClient
    private let http: any ContextAnalysisHTTPClient
    private let cloud: CloudRemoteRequestClient
    private let intentsURL: URL?
    private struct Intent: Codable { var result: ExamAssessmentResult? }
    private var intents: [String: Intent] = [:]
    private var loadFailed = false

    init(api: ExamAPIClient = ExamAPIClient(),
         http: any ContextAnalysisHTTPClient = URLSessionContextAnalysisHTTPClient(),
         cloud: CloudRemoteRequestClient = .shared, intentsURL: URL? = nil) {
        self.api = api; self.http = http; self.cloud = cloud
        self.intentsURL = intentsURL ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask).first?.appending(path: "ExamAssessmentIntents.json")
        if let file = self.intentsURL, FileManager.default.fileExists(atPath: file.path) {
            do { intents = try JSONDecoder().decode([String: Intent].self, from: Data(contentsOf: file)) }
            catch { loadFailed = true }
        }
    }

    func assess(examID: String, revision: String, attemptID: String, taskID: String,
                responses: [String: String]) async throws -> ExamAssessmentResult {
        let settings = TranslationRequestSettings.current
        let identity = try await api.identity()
        let scope = identity.scopeID
        let data = try await api.send("v1/exam-attempts/\(attemptID)/assessment/\(taskID)", expectedScope: scope)
        guard let context = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = context["request"] as? [String: Any],
              request["exam_id"] as? String == examID, request["revision"] as? String == revision,
              request["task_id"] as? String == taskID,
              let contract = context["contract"] as? [String: Any],
              let maximum = contract["max_score_units"] as? Int,
              let payload = request["payload"] as? [String: Any],
              let selected = payload["responses"] as? [[String: String]],
              selected.allSatisfy({ responses[$0["item_id"] ?? "", default: ""] == $0["text"] }) else {
            throw ContextAnalysisError.invalidOutput
        }
        let result: ExamAssessmentResult
        if settings.mode == .subscription {
            let body = try JSONSerialization.data(withJSONObject: [
                "attempt_id": attemptID, "task_id": taskID, "feedback_language": "pl",
                "model": settings.model.rawValue, "reasoning_effort": settings.reasoningEffort
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            let response = try await cloud.runAssessment(body: body)
            guard response.kind == "exam_assessment", let value = response.result,
                  let score = value.score_units, let rationale = value.rationale else {
                throw ContextAnalysisError.invalidOutput
            }
            result = .init(scoreUnits: score, rationale: rationale)
        } else {
            guard var body = request["provider_body_template"] as? [String: Any],
                  let key = try OpenAIAPIKeyStore.load(), !key.isEmpty else {
                throw ContextAnalysisError.missingConfiguration
            }
            body["model"] = settings.model.rawValue
            body["reasoning"] = ["effort": settings.reasoningEffort]
            body["max_output_tokens"] = ReasoningRequestBudget.outputTokens(effort: settings.reasoningEffort, base: 4096)
            let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            let fingerprint = SHA256.hash(data: Data(scope.utf8) + bodyData).map { String(format: "%02x", $0) }.joined()
            guard !loadFailed else { throw ContextAnalysisError.persistence }
            if let existing = intents[fingerprint] {
                guard let saved = existing.result else { throw ContextAnalysisError.cloudOutcomeUnknown }
                result = saved
            } else {
                // Persist admission before POST. A timeout/process death never silently makes another paid request.
                var next = intents; next[fingerprint] = Intent(result: nil)
                try persist(next); intents = next
                var call = URLRequest(url: OpenAIContextAnalysisProvider.endpoint)
                call.httpMethod = "POST"; call.httpBody = bodyData
                call.timeoutInterval = ReasoningRequestBudget.timeout(effort: settings.reasoningEffort)
                call.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                call.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (raw, response) = try await http.data(for: call)
                guard (200..<300).contains(response.statusCode), raw.count <= 131072,
                      let envelope = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                      envelope["status"] as? String == "completed",
                      let output = envelope["output"] as? [[String: Any]] else {
                    throw ContextAnalysisError.invalidOutput
                }
                let content = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                guard !content.contains(where: { $0["type"] as? String == "refusal" }) else {
                    throw ContextAnalysisError.invalidOutput
                }
                let text = content.filter { $0["type"] as? String == "output_text" }
                    .compactMap { $0["text"] as? String }.joined()
                guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      Set(value.keys) == ["score_units", "rationale"] else { throw ContextAnalysisError.invalidOutput }
                result = try JSONDecoder().decode(ExamAssessmentResult.self, from: Data(text.utf8))
                try Self.validate(result, maximum: maximum)
                next[fingerprint] = Intent(result: result); try persist(next); intents = next
            }
        }
        try Self.validate(result, maximum: maximum)
        guard TranslationRequestSettings.current.mode == settings.mode else { throw ContextAnalysisError.cancelled }
        // This endpoint stores client results with explicit provenance, never as a server AI execution.
        if settings.mode == .personalKey {
            let value: [String: Any] = ["result": ["score_units": result.scoreUnits, "rationale": result.rationale],
                "provenance": ["provider": "openai", "mode": "personalKey", "model": settings.model.rawValue,
                    "reasoning_effort": settings.reasoningEffort, "revision": revision,
                    "contract_sha256": contract["contract_sha256"] as? String ?? ""]]
            _ = try await api.send("v1/exam-attempts/\(attemptID)/assessment/\(taskID)", method: "POST",
                body: JSONSerialization.data(withJSONObject: value), expectedScope: scope)
        }
        return result
    }

    static func validate(_ value: ExamAssessmentResult, maximum: Int) throws {
        guard value.scoreUnits >= 0, value.scoreUnits <= maximum, value.scoreUnits % 25 == 0,
              !value.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.rationale.count <= 8000 else { throw ContextAnalysisError.invalidOutput }
    }

    private func persist(_ value: [String: Intent]) throws {
        guard let file = intentsURL else { throw ContextAnalysisError.persistence }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtection])
    }
}
