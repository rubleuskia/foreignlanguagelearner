import XCTest
@testable import ForeignLanguageLearner

final class ListeningPracticeTests: XCTestCase {

    func testDictionaryAnswerPreservesExactTextAndRejectsMatchingDistractor() throws {
        let answer = "  Он согласился.  "
        let choices = ListeningChoices(correct: answer, distractors: ["Он отказался.", "Он предложил.", "Он признался.", "Он попросил."])
        XCTAssertEqual(try choices.validated().correct, answer)
        XCTAssertThrowsError(try ListeningChoices(correct: answer, distractors: ["Он согласился.", "Он предложил.", "Он признался.", "Он попросил."]).validated())
    }

    func testRejectsMissingDuplicateAndEmptyChoices() {
        XCTAssertThrowsError(try ListeningChoices(correct: "да", distractors: ["нет"]).validated())
        XCTAssertThrowsError(try ListeningChoices(correct: "да", distractors: [" Да ", "нет", "возможно", "позже"]).validated())
        XCTAssertThrowsError(try ListeningChoices(correct: "да", distractors: ["", "нет", "возможно", "позже"]).validated())
    }

    func testDictionaryAnswerIsAuthoritativeEvenIfModelReturnsAnotherCorrectAnswer() async throws {
        let result = ListeningChoices(correct: "Он согласился.", distractors: ["Он отказался.", "Он предложил.", "Он признался.", "Он попросил."])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: [
            "correct": "Invented model translation", "distractors": result.distractors
        ]), as: UTF8.self)
        let response = try JSONSerialization.data(withJSONObject: ["id": "test", "status": "completed", "output": [["content": [["type": "output_text", "text": encoded]]]]])
        let client = ListeningHTTPClient(response: response)
        let input = ListeningInput(phrase: "He agreed.", dictionaryTranslation: result.correct, sourceLanguage: "en", targetLanguage: "ru")
        let output = try await OpenAIListeningProvider(apiKey: "test", model: .mini, client: client).generate(input)
        XCTAssertEqual(output, result)
        let requests = await client.requests
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        let inputString = try XCTUnwrap(body["input"] as? String)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(inputString.utf8)) as? [String: String])
        XCTAssertEqual(fields, ["phrase": "He agreed.", "dictionaryTranslation": result.correct, "sourceLanguage": "en", "targetLanguage": "ru"])
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["distractors"])
        XCTAssertFalse(OpenAIListeningProvider.prompt.lowercased().contains("audio"))
    }
}

private actor ListeningHTTPClient: ContextAnalysisHTTPClient {
    let response: Data
    private(set) var requests: [URLRequest] = []
    init(response: Data) { self.response = response }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
