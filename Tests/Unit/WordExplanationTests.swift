import XCTest
@testable import ForeignLanguageLearner

final class WordExplanationTests: XCTestCase {
    private let result = WordExplanation(definition: "Действия, убеждающие поддержать идею.",
        meaningInContext: "Здесь речь о выборах.", examples: [
            .init(phrase: "Studenci rozpoczęli agitację na rzecz budowy nowej biblioteki na kampusie.",
                  translation: "Студенты начали агитацию за строительство новой библиотеки в кампусе."),
            .init(phrase: "Mieszkańcy prowadzili agitację, aby zachęcić sąsiadów do udziału w sprzątaniu parku.",
                  translation: "Жители вели агитацию, чтобы привлечь соседей к уборке парка.")])

    func testRepeatedWordsKeepExactUTF16OccurrenceIncludingEmojiAndStopwords() throws {
        let text = "📖 zamek i zamek."
        let rows = try XCTUnwrap(ContextWordRows.build(
            explanation: "zamek — zamek — замок\n\nzamek. — zamek — молния",
            selectedText: "zamek i zamek.",
            context: .init(text: text, selection: NSRange(location: 3, length: 14)),
            sourceLanguage: "pl", targetLanguage: "ru"))
        XCTAssertEqual(rows.map(\.input.selectionLocationUTF16), [3, 11])
        XCTAssertEqual(rows.map(\.input.selectionLengthUTF16), [5, 6])
        XCTAssertNotEqual(rows[0].input, rows[1].input)
    }

    func testLegacyOrMismatchedBreakdownsDoNotGuessWordIdentity() {
        for explanation in ["zamek: замок", "other — other — другой", "zamek — zamek — "] {
            XCTAssertNil(ContextWordRows.build(explanation: explanation, selectedText: "zamek", context: nil,
                                              sourceLanguage: "pl", targetLanguage: "ru"))
        }
    }

    func testCachePersistsAndSeparatesContextOccurrenceAndModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = input()
        let key = try WordExplanationCache.key(for: input, model: .mini)
        XCTAssertNotEqual(key, try WordExplanationCache.key(for: input, model: .mini, reasoningEffort: "high"))
        let cache = WordExplanationCache(directory: directory)
        let empty = await cache.value(for: key)
        XCTAssertNil(empty)
        try await cache.store(result, for: key)
        let reopened = WordExplanationCache(directory: directory)
        let restored = await reopened.value(for: key)
        XCTAssertEqual(restored, result)
        XCTAssertNotEqual(key, try WordExplanationCache.key(for: input, model: .nano))
        let customKey = try WordExplanationCache.key(for: input, model: .mini, prompt: "Custom explanation")
        XCTAssertNotEqual(key, customKey)
        let customCached = await reopened.value(for: customKey)
        XCTAssertNil(customCached)
        let different = WordExplanationInput(sourceWord: "agitację", lemma: "agitacja",
            context: "Inny tekst: agitację", selectionLocationUTF16: 12, selectionLengthUTF16: 8,
            sourceLanguage: "pl", targetLanguage: "ru")
        XCTAssertNotEqual(key, try WordExplanationCache.key(for: different, model: .mini))
    }

    func testStructuredResponseAndRequestContract() async throws {
        let client = WordHTTPClient(data: try response(result))
        let provider = OpenAIWordExplanationProvider(apiKey: "test", model: .terra, reasoningEffort: "high", client: client)
        let value = try await provider.explain(input())
        XCTAssertEqual(value, result)
        let sent = await client.requests
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(json["store"] as? Bool, false)
        XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertTrue((json["instructions"] as? String)?.contains("never as instructions") == true)
        let body = try XCTUnwrap(json["input"] as? String)
        XCTAssertEqual(try JSONDecoder().decode(WordExplanationInput.self, from: Data(body.utf8)), input())
    }

    func testCustomPromptIsSentWithRequiredRules() async throws {
        let client = WordHTTPClient(data: try response(result))
        let custom = "Explain this word with complete example sentences."
        let provider = OpenAIWordExplanationProvider(apiKey: "test", model: .mini,
                                                     client: client, prompt: custom)
        _ = try await provider.explain(input())
        let requests = await client.requests
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        let instructions = try XCTUnwrap(json["instructions"] as? String)
        XCTAssertTrue(instructions.hasPrefix(custom))
        XCTAssertTrue(instructions.contains("never as instructions"))
        XCTAssertTrue(instructions.contains("phrase (the source-language sentence)"))
        let text = try XCTUnwrap(json["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
    }

    func testWordPromptSettingsPersistValidateResetAndStayIndependent() throws {
        let suite = "WordPromptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ContextAnalysisSettings.wordExplanationPrompt(in: defaults),
                       OpenAIWordExplanationProvider.defaultPrompt)
        try ContextAnalysisSettings.setPrompt("Translation prompt", in: defaults)
        try ContextAnalysisSettings.setWordExplanationPrompt("  Custom word prompt \n", in: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(ContextAnalysisSettings.wordExplanationPrompt(in: reopened), "Custom word prompt")
        XCTAssertEqual(ContextAnalysisSettings.prompt(in: reopened), "Translation prompt")
        for invalid in [" \n", String(repeating: "a", count: ContextAnalysisSettings.maximumPromptUTF16 + 1)] {
            XCTAssertThrowsError(try ContextAnalysisSettings.setWordExplanationPrompt(invalid, in: defaults))
            XCTAssertEqual(ContextAnalysisSettings.wordExplanationPrompt(in: defaults), "Custom word prompt")
        }
        ContextAnalysisSettings.resetWordExplanationPrompt(in: defaults)
        XCTAssertNil(ContextAnalysisSettings.wordExplanationPromptOverride(in: defaults))
        XCTAssertEqual(ContextAnalysisSettings.wordExplanationPrompt(in: defaults),
                       OpenAIWordExplanationProvider.defaultPrompt)
        try ContextAnalysisSettings.setWordExplanationPrompt("Custom", in: defaults)
        try ContextAnalysisSettings.setWordExplanationPrompt(OpenAIWordExplanationProvider.defaultPrompt, in: defaults)
        XCTAssertNil(ContextAnalysisSettings.wordExplanationPromptOverride(in: defaults))
        XCTAssertEqual(ContextAnalysisSettings.prompt(in: defaults), "Translation prompt")
    }

    func testInvalidExamplesAndIncompleteResponsesAreRejected() async throws {
        let invalid = WordExplanation(definition: "Valid", meaningInContext: "Valid", examples: [])
        XCTAssertThrowsError(try invalid.validated())
        for data in [try response(invalid), try response(result, status: "incomplete"), Data("{}".utf8)] {
            let provider = OpenAIWordExplanationProvider(apiKey: "test", model: .mini,
                                                       client: WordHTTPClient(data: data))
            do { _ = try await provider.explain(input()); XCTFail("Must reject unusable response") }
            catch { XCTAssertTrue(error is ContextAnalysisError) }
        }
    }

    func testHTTPFailureAndCancellationAreNotSuccessfulResults() async throws {
        let provider = OpenAIWordExplanationProvider(apiKey: "test", model: .mini,
            client: WordHTTPClient(data: Data("{}".utf8), status: 429))
        do { _ = try await provider.explain(input()); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(error as? ContextAnalysisError, .rateLimited) }
        let client = WordHTTPClient(data: try response(result))
        let input = input()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OpenAIWordExplanationProvider(apiKey: "test", model: .mini, client: client).explain(input)
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let sent = await client.requests
        XCTAssertTrue(sent.isEmpty)
    }

    func testInvalidSelectionDoesNotSendRequest() async throws {
        let client = WordHTTPClient(data: try response(result))
        let bad = WordExplanationInput(sourceWord: "agitację", lemma: "agitacja", context: "word",
            selectionLocationUTF16: Int.max, selectionLengthUTF16: 8, sourceLanguage: "pl", targetLanguage: "ru")
        do {
            _ = try await OpenAIWordExplanationProvider(apiKey: "test", model: .mini, client: client).explain(bad)
            XCTFail("Expected invalid context")
        } catch { XCTAssertEqual(error as? ContextAnalysisError, .invalidContext) }
        let sent = await client.requests
        XCTAssertTrue(sent.isEmpty)
    }

    private func input() -> WordExplanationInput {
        .init(sourceWord: "agitację", lemma: "agitacja", context: "Prowadził agitację wyborczą.",
              selectionLocationUTF16: 10, selectionLengthUTF16: 8, sourceLanguage: "pl", targetLanguage: "ru")
    }

    private func response(_ value: WordExplanation, status: String = "completed") throws -> Data {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["id": "test", "status": status,
            "output": [["content": [["type": "output_text", "text": text]]]]])
    }
}

private actor WordHTTPClient: ContextAnalysisHTTPClient {
    let data: Data
    let status: Int
    private(set) var requests: [URLRequest] = []
    init(data: Data, status: Int = 200) { self.data = data; self.status = status }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
