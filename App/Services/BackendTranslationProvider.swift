import Foundation
import CryptoKit

struct CloudTranslationPayload: Encodable, Sendable {
    let schemaVersion = 1
    let selectedText: String
    let context: String
    let selectionLocationUTF16: Int
    let selectionLengthUTF16: Int
    let sourceLanguage: String
    let targetLanguage: String
    let wordsToExplain: [String]?
    let lemma: String?
    let model: String
    let reasoningEffort: String
    enum CodingKeys: String, CodingKey {
        case model, reasoningEffort = "reasoning_effort"
        case schemaVersion = "schema_version", selectedText = "selected_text", context
        case selectionLocationUTF16 = "selection_location_utf16", selectionLengthUTF16 = "selection_length_utf16"
        case sourceLanguage = "source_language", targetLanguage = "target_language", wordsToExplain = "words_to_explain", lemma
    }
    init(_ request: ContextAnalysisRequest, settings: TranslationRequestSettings? = nil) {
        let settings = settings ?? request.execution ?? .current
        model = settings.model.rawValue; reasoningEffort = settings.reasoningEffort
        selectedText = request.selectedText; context = request.contextFragment
        selectionLocationUTF16 = request.selectionLocationUTF16; selectionLengthUTF16 = request.selectionLengthUTF16
        sourceLanguage = SourceLanguage.canonical(request.sourceLanguage); targetLanguage = request.targetLanguage
        wordsToExplain = request.wordsToExplain; lemma = nil
    }
    init(_ input: WordExplanationInput, settings: TranslationRequestSettings? = nil) {
        let settings = settings ?? input.execution ?? .current
        model = settings.model.rawValue; reasoningEffort = settings.reasoningEffort
        selectedText = input.sourceWord; context = input.context
        selectionLocationUTF16 = input.selectionLocationUTF16; selectionLengthUTF16 = input.selectionLengthUTF16
        sourceLanguage = SourceLanguage.canonical(input.sourceLanguage); targetLanguage = input.targetLanguage; lemma = input.lemma; wordsToExplain = nil
    }
    func validate(kind: String) throws {
        guard SourceLanguage.supportedCodes.contains(sourceLanguage), targetLanguage == "ru" else { throw ContextAnalysisError.invalidLanguage }
        guard !selectedText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              selectedText.utf16.count <= (kind == "context" && wordsToExplain?.isEmpty == true ? 1400 : 256),
              !context.isEmpty, context.utf16.count <= 1400 else { throw ContextAnalysisError.inputTooLarge }
        guard selectionLocationUTF16 >= 0, selectionLengthUTF16 == selectedText.utf16.count,
              selectionLocationUTF16 <= context.utf16.count,
              selectionLengthUTF16 <= context.utf16.count - selectionLocationUTF16,
              let range = Range(NSRange(location:selectionLocationUTF16,length:selectionLengthUTF16),in:context),
              String(context[range]) == selectedText else { throw ContextAnalysisError.invalidContext }
        if kind == "word" {
            guard let lemma, !lemma.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, lemma.utf16.count<=256 else { throw ContextAnalysisError.invalidContext }
        } else {
            guard kind == "context", let wordsToExplain, wordsToExplain.count<=128 else { throw ContextAnalysisError.invalidContext }
        }
    }

}

struct CloudRequestEnvelope: Decodable, Sendable {
    struct ResultValue: Decodable, Sendable {
        struct Word: Decodable, Sendable { let source_word: String; let lemma: String; let meaning: String }
        let phrase_translation: String?
        let word_explanations: [Word]?
        let definition: String?
        let meaningInContext: String?
        let examples: [WordExplanation.Example]?
    }
    let schema_version: Int
    let request_id: String
    let state: String
    let policy_version: String
    let kind: String
    let result: ResultValue?
}

actor CloudRequestLedger {
    struct Entry: Codable, Sendable, Identifiable, Equatable {
        let scopeID: String
        let owner: String
        let fingerprint: String
        let idempotencyKey: UUID
        let kind: String
        let createdAt: Date
        var policyVersion: String?
        var state: String?
        var id: UUID { idempotencyKey }
    }
    static var defaultURL: URL? { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("CloudRequests-v1.json") }
    private let file: URL?
    private var entries: [Entry]
    private var loadFailed = false
    init(file: URL? = CloudRequestLedger.defaultURL) {
        self.file = file
        entries = []
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do { entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)) }
            catch { loadFailed = true }
        }
    }
    func list(_ lease: CloudSession.Lease) throws -> [Entry] {
        guard !loadFailed else { throw ContextAnalysisError.persistence }
        return entries.filter { $0.scopeID == lease.scopeID && $0.owner == lease.userID }
    }
    func entry(_ lease: CloudSession.Lease, fingerprint: String, kind: String, policyVersion: String = "cloud-v1",
               legacyFingerprint: String? = nil) throws -> Entry {
        if let legacyFingerprint, try list(lease).contains(where: {
            $0.fingerprint == legacyFingerprint && ($0.state == nil || ["accepted", "running", "outcome_unknown"].contains($0.state ?? ""))
        }) {
            // Old ledgers did not record model settings. Do not silently create another paid intent.
            throw ContextAnalysisError.cloudOutcomeUnknown
        }
        if let existing = try list(lease).last(where: {
            $0.fingerprint == fingerprint && ($0.state != "succeeded" || $0.policyVersion == policyVersion)
        }) { return existing }
        // Never evict an unresolved intent automatically; losing its key could duplicate spend.
        guard entries.count < 1000 else { throw ContextAnalysisError.busy }
        let next = Entry(scopeID: lease.scopeID, owner: lease.userID, fingerprint: fingerprint,
            idempotencyKey: UUID(), kind: kind, createdAt: Date(), policyVersion: policyVersion, state: nil)
        try persist(entries + [next]); entries.append(next)
        return next
    }
    func mark(_ entry: Entry, state: String, policyVersion: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { throw ContextAnalysisError.persistence }
        var next = entries; next[index].state = state; next[index].policyVersion = policyVersion
        try persist(next); entries = next
    }
    func forget(_ entry: Entry) throws {
        let next = entries.filter { $0.id != entry.id }; try persist(next); entries = next
    }
    private func persist(_ next: [Entry]) throws {
        guard var file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try file.setResourceValues(values)
    }
}

actor CloudRemoteRequestClient {
    static let shared = CloudRemoteRequestClient()
    private let session: CloudSession
    private let ledger: CloudRequestLedger
    init(session: CloudSession = .shared, ledger: CloudRequestLedger = CloudRequestLedger()) {
        self.session = session; self.ledger = ledger
    }
    func run(kind: String, payload: CloudTranslationPayload) async throws -> CloudRequestEnvelope {
        try payload.validate(kind:kind)
        let lease = try await session.lease()
        struct Policy: Decodable { let policy_version: String }
        let statusData = try await session.send("v1/me/entitlements", expected: lease)
        let policy = try JSONDecoder().decode(Policy.self, from: statusData)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(payload)
        let digest = SHA256.hash(data: Data("\(kind)|".utf8) + body).map { String(format: "%02x", $0) }.joined()
        guard var legacy = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ContextAnalysisError.invalidOutput
        }
        legacy.removeValue(forKey: "model"); legacy.removeValue(forKey: "reasoning_effort")
        let legacyBody = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys, .withoutEscapingSlashes])
        let legacyDigest = SHA256.hash(data: Data("\(kind)|".utf8) + legacyBody).map { String(format: "%02x", $0) }.joined()
        let entry = try await ledger.entry(lease, fingerprint: digest, kind: kind,
            policyVersion: policy.policy_version, legacyFingerprint: legacyDigest)
        let path = kind == "context" ? "v1/context-analyses" : "v1/word-explanations"
        guard CloudProviderMode.current == .subscription else { throw CloudAPIError(code: "ACCOUNT_CHANGED") }
        let data = try await session.send(path, method: "POST", body: body, idempotencyKey: entry.idempotencyKey, expected: lease)
        var envelope = try JSONDecoder().decode(CloudRequestEnvelope.self, from: data)
        let deadline = Date().addingTimeInterval(180)
        var delay = 1
        for _ in 0..<30 {
            try Task.checkCancellation(); try await session.validate(lease)
            guard CloudProviderMode.current == .subscription else { throw CloudAPIError(code: "ACCOUNT_CHANGED") }
            try await ledger.mark(entry, state: envelope.state, policyVersion: envelope.policy_version)
            switch envelope.state {
            case "succeeded": return envelope
            case "failed": throw CloudAPIError(code: "REQUEST_FAILED")
            case "outcome_unknown": throw CloudAPIError(code: "OUTCOME_UNKNOWN")
            case "cancelled": throw CloudAPIError(code: "CANCELLED")
            case "accepted", "running": break
            default: throw ContextAnalysisError.invalidOutput
            }
            guard Date() < deadline else { throw ContextAnalysisError.timeout }
            try await Task.sleep(for: .seconds(delay)); delay = min(10, delay * 2)
            let data = try await session.send("v1/requests/\(envelope.request_id)", expected: lease)
            envelope = try JSONDecoder().decode(CloudRequestEnvelope.self, from: data)
        }
        throw ContextAnalysisError.timeout
    }
    func entries() async throws -> [CloudRequestLedger.Entry] { try await ledger.list(try await session.lease()) }
    func resume(_ entry: CloudRequestLedger.Entry) async throws -> CloudRequestEnvelope {
        let lease = try await session.lease()
        guard entry.owner == lease.userID, entry.scopeID == lease.scopeID else { throw CloudAPIError(code: "ACCOUNT_CHANGED") }
        let data = try await session.send("v1/requests/by-key/\(entry.idempotencyKey.uuidString)", expected: lease)
        let envelope = try JSONDecoder().decode(CloudRequestEnvelope.self, from: data)
        try await ledger.mark(entry, state: envelope.state, policyVersion: envelope.policy_version)
        return envelope
    }
    func cancel(_ entry: CloudRequestLedger.Entry) async throws -> CloudRequestEnvelope {
        let envelope = try await resume(entry)
        let lease = try await session.lease()
        guard entry.owner == lease.userID, entry.scopeID == lease.scopeID else { throw CloudAPIError(code: "ACCOUNT_CHANGED") }
        let data = try await session.send("v1/requests/\(envelope.request_id)/cancel", method: "POST", expected: lease)
        return try JSONDecoder().decode(CloudRequestEnvelope.self, from: data)
    }
    func forget(_ entry: CloudRequestLedger.Entry) async throws {
        do {
            let state = try await resume(entry).state
            guard !["accepted", "running"].contains(state) else { throw ContextAnalysisError.busy }
        } catch let error as CloudAPIError where ["REQUEST_EXPIRED", "RESULT_EXPIRED", "NOT_FOUND"].contains(error.code) {
            // A missing server record is not forgotten while its original admission may still be in flight.
            guard Date().timeIntervalSince(entry.createdAt) > 600 else { throw ContextAnalysisError.busy }
        }
        try await ledger.forget(entry)
    }
}

struct BackendContextAnalysisProvider: ContextAnalysisProvider {
    var client: CloudRemoteRequestClient = .shared
    var settings: TranslationRequestSettings? = nil
    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult {
        do {
            let response = try await client.run(kind: "context", payload: .init(request, settings: settings))
            guard response.schema_version == 1, response.kind == "context", let result = response.result,
                  let translation = result.phrase_translation, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  translation.utf16.count <= request.maximumTranslationUTF16, let rows = result.word_explanations else { throw ContextAnalysisError.invalidOutput }
            let expected = request.wordsToExplain
            guard rows.map(\.source_word) == expected, rows.allSatisfy({ !$0.lemma.isEmpty && !$0.meaning.isEmpty }) else { throw ContextAnalysisError.invalidOutput }
            let lines = rows.map { "\($0.source_word) — \($0.lemma) — \($0.meaning)" }.joined(separator: "\n\n")
            guard lines.utf16.count <= 2000 else { throw ContextAnalysisError.invalidOutput }
            return ContextualPhraseResult(directTranslation: translation, contextExplanation: lines)
        } catch let error as CloudAPIError { throw error.analysisError }
        catch let error as URLError {
            switch error.code {
            case .cancelled: throw ContextAnalysisError.cancelled
            case .timedOut: throw ContextAnalysisError.timeout
            default: throw ContextAnalysisError.networkUnavailable
            }
        }
    }
}

struct BackendWordExplanationProvider: Sendable {
    var client: CloudRemoteRequestClient = .shared
    var settings: TranslationRequestSettings? = nil
    func explain(_ input: WordExplanationInput) async throws -> WordExplanation {
        do {
            let response = try await client.run(kind: "word", payload: .init(input, settings: settings))
            guard response.schema_version == 1, response.kind == "word", let value = response.result,
                  let definition = value.definition, let meaning = value.meaningInContext, let examples = value.examples else { throw ContextAnalysisError.invalidOutput }
            return try WordExplanation(definition: definition, meaningInContext: meaning, examples: examples).validated()
        } catch let error as CloudAPIError { throw error.analysisError }
        catch let error as URLError {
            switch error.code {
            case .cancelled: throw ContextAnalysisError.cancelled
            case .timedOut: throw ContextAnalysisError.timeout
            default: throw ContextAnalysisError.networkUnavailable
            }
        }
    }
}
