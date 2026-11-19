import Foundation
import XCTest
import UIKit
@testable import ForeignLanguageLearner

@MainActor final class ExamServicesTests: XCTestCase {
    private let scopeA = String(repeating: "a", count: 64)
    private let scopeB = String(repeating: "b", count: 64)

    func testSourceIllustrationsRenderOnlyAnExistingLocalPDFPage() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "exam-picture-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        try renderer.pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            UIBezierPath(ovalIn: CGRect(x: 20, y: 20, width: 60, height: 60)).fill()
        }.write(to: file)
        var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
        components.fragment = "page=1"
        XCTAssertNotNil(ExamSourcePageRenderer.thumbnail(url: components.url!, page: 1))
        XCTAssertNil(ExamSourcePageRenderer.thumbnail(url: file, page: 0))
        XCTAssertNil(ExamSourcePageRenderer.thumbnail(url: file, page: 2))
        XCTAssertNil(ExamSourcePageRenderer.thumbnail(url: URL(string: "https://example.test/paper.pdf")!, page: 1))
    }

    func testAnswerAndFrozenOutboxSurviveRelaunchAndRemainOwnerScoped() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "exam-state-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ExamPersistence(root: root)
        var state = ExamLocalState(scopeID: scopeA, deviceID: "device-a")
        var attempt = ExamAttempt(examID: "pilot", revision: String(repeating: "c", count: 64), mode: .training, sectionID: "grammar", deviceID: state.deviceID)
        attempt.responses["opaque-item"] = .text("wziął; ąęć")
        attempt.progress.audioCursorMS = 91234
        state.attempts = [attempt]
        var event = ExamSyncEvent(attemptID: attempt.id, kind: .update, body: ["responses": .object(["opaque-item": .string("wziął; ąęć")])])
        event.sentBaseVersion = 7
        event.body["base_version"] = .number(7)
        event.body["change_id"] = .string(event.id.uuidString.lowercased())
        state.outbox = [event]
        try storage.commit(state)
        let reopened = try ExamPersistence(root: root).load(scopeID: scopeA)
        XCTAssertEqual(reopened.attempts[0].responses["opaque-item"], .text("wziął; ąęć"))
        XCTAssertEqual(reopened.attempts[0].progress.audioCursorMS, 91234)
        XCTAssertEqual(reopened.outbox[0].id, event.id)
        XCTAssertEqual(reopened.outbox[0].body, event.body)
        XCTAssertEqual(reopened.outbox[0].sentBaseVersion, 7)
        XCTAssertTrue(try storage.load(scopeID: scopeB).attempts.isEmpty)
        XCTAssertTrue(try storage.load(scopeID: scopeB).outbox.isEmpty)
    }

    func testCorruptStateIsNotSilentlyReplacedByAnEmptyDraft() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "exam-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ExamPersistence(root: root)
        try storage.commit(ExamLocalState(scopeID: scopeA))
        let file = root.appending(path: scopeA + "/state.json")
        let corrupted = Data("{broken".utf8)
        try corrupted.write(to: file)
        XCTAssertThrowsError(try storage.load(scopeID: scopeA))
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
    }

    func testActiveStudentMaterialRejectsKeysButPreservesSolvedExamples() throws {
        XCTAssertThrowsError(try ExamAPIClient.rejectPrivateKeys(["sections": [["tasks": [["items": [["grading": ["accepted_answers": ["a"]]]]]]]]]))
        XCTAssertThrowsError(try ExamAPIClient.rejectPrivateKeys(["source_refs": [["source_id": "keys", "page": 6]]]))
        XCTAssertNoThrow(try ExamAPIClient.rejectPrivateKeys(["blocks": [["type": "example", "answer": "C", "source_refs": [["source_id": "paper", "page": 13]]]]]))
    }

    func testAIUnknownScoreBecomesTaskScoreWithoutInferringTaskIDFromItemID() {
        let rows = (1...5).map { ExamItemResult(itemID: "opaque-\($0)", taskID: "grammar-V", status: "pending_ai", awardedScoreUnits: nil, maxScoreUnits: 50) }
        let section = ExamSectionResult(sectionID: "grammar", status: "pending", scoreUnits: nil, objectiveScoreUnits: 0, maxScoreUnits: 250, items: rows, taskAssessments: [])
        let result = ExamAttemptResult(examID: "pilot", revision: "revision", sections: [section])
        let pending = result.summary(for: "grammar", assessments: [:])
        XCTAssertNil(pending?.totalScoreUnits)
        XCTAssertEqual(pending?.pendingScoreUnits, 250)
        let completed = result.summary(for: "grammar", assessments: ["grammar-V": ExamAssessmentResult(scoreUnits: 175, rationale: "Verified partial credit.")])
        XCTAssertEqual(completed?.totalScoreUnits, 175)
        XCTAssertEqual(completed?.pendingScoreUnits, 0)
    }

    func testAIResultDoesNotCompleteManualFieldsInTheSameOpaqueTask() {
        let rows = [
            ExamItemResult(itemID: "closed", taskID: "opaque-task", status: "correct", awardedScoreUnits: 50, maxScoreUnits: 50),
            ExamItemResult(itemID: "free", taskID: "opaque-task", status: "pending_ai", awardedScoreUnits: nil, maxScoreUnits: 100),
            ExamItemResult(itemID: "ambiguous", taskID: "opaque-task", status: "pending_manual", awardedScoreUnits: nil, maxScoreUnits: 50)]
        let section = ExamSectionResult(sectionID: "grammar", status: "pending", scoreUnits: nil,
            objectiveScoreUnits: 50, maxScoreUnits: 200, items: rows, taskAssessments: [])
        let result = ExamAttemptResult(examID: "synthetic", revision: "revision", sections: [section])
        let summary = result.summary(for: "grammar", assessments: ["opaque-task": ExamAssessmentResult(scoreUnits: 75, rationale: "AI fields only.")])
        XCTAssertEqual(summary?.pendingScoreUnits, 50)
        XCTAssertEqual(summary?.objectiveScoreUnits, 50)
        XCTAssertEqual(summary?.autoMaxScoreUnits, 50)
        XCTAssertNil(summary?.totalScoreUnits)
    }

    func testTrainingAudioIsBoundedAndExamUsesOriginalFullTimeline() {
        let windows = ["listening-I": 10.0...35.0]
        let training = ExamAudioPlaybackPolicy(mode: .training, duration: 100, windows: windows)
        XCTAssertTrue(training.allowsUserTransport)
        XCTAssertEqual(training.clampedPosition(2, taskID: "listening-I"), 10)
        XCTAssertEqual(training.clampedPosition(70, taskID: "listening-I"), 35)
        let exam = ExamAudioPlaybackPolicy(mode: .exam, duration: 100, windows: windows)
        XCTAssertFalse(exam.allowsUserTransport)
        XCTAssertEqual(exam.clampedPosition(70, taskID: "listening-I"), 70)
        XCTAssertEqual(exam.clampedPosition(104, taskID: nil), 100)
    }

    func testCloudRequestDefaultTimeoutIsUnchangedAndBinaryOverrideIsExplicit() async throws {
        let config = try CloudConfiguration(info: ["CloudAPIBaseURL": "https://api.example.test", "CloudCognitoDomain": "https://login.example.test",
            "CloudPrivacyURL": "https://example.test/privacy", "CloudTermsURL": "https://example.test/terms", "CloudSupportURL": "https://example.test/support",
            "CloudClientID": "client", "CloudCallbackURL": "fll://auth", "CloudEnvironment": "Sandbox", "CloudProducts": ["test.product"]])
        let credentials = CloudCredentials(scopeID: config.scopeID, userID: "user", appAccountToken: UUID(), accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(900))
        let http = ExamHTTPProbe()
        let session = CloudSession(configuration: config, store: ExamCloudMemoryStore(credentials), client: http)
        _ = try await session.send("v1/exams")
        _ = try await session.send("v1/exams/source/content", timeout: 900)
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.timeoutInterval), [25, 900])
    }
}

private final class ExamCloudMemoryStore: CloudCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: CloudCredentials?
    init(_ value: CloudCredentials?) { self.value = value }
    func load() throws -> CloudCredentials? { lock.withLock { value } }
    func save(_ value: CloudCredentials?) throws { lock.withLock { self.value = value } }
}

private actor ExamHTTPProbe: ContextAnalysisHTTPClient {
    var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
