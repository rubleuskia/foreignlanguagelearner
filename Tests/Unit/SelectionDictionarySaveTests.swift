import SwiftData
import XCTest
@testable import ForeignLanguageLearner

private actor CountingAnalysisService: ContextAnalysisServing {
    private(set) var calls = 0
    let error: ContextAnalysisError?
    init(error: ContextAnalysisError? = nil) { self.error = error }
    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult {
        calls += 1
        if let error { throw error }
        return .init(directTranslation: "молния", contextExplanation: "zamek — zamek — молния")
    }
}

@MainActor
final class SelectionDictionarySaveTests: XCTestCase {
    private func fixture() throws -> (ModelContainer, LearningItem, SelectionTranslationPreview) {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "track.m4a", transcriptFilename: "story.srt",
                                duration: 100, segments: [])
        container.mainContext.insert(item)
        try container.mainContext.save()
        let source = "Zepsuł się zamek w kurtce."
        let preview = SelectionTranslationPreview(
            selectedText: "zamek", sourceLanguageCode: "pl",
            context: .init(text: source, selection: (source as NSString).range(of: "zamek")),
            sourceItemID: item.id, sourceTitle: item.title, audioRange: 3...5,
            sourceTrackID: "track-2", segmentIndex: 4
        )
        return (container, item, preview)
    }

    private func waitUntilFinished(_ coordinator: SelectionTranslationCoordinator) async throws {
        for _ in 0..<100 {
            if coordinator.currentRequest() == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Analysis did not finish")
    }

    func testDirectSaveRequestsAnalysisFirstAndPersistsBothResultsOnce() async throws {
        let (container, _, preview) = try fixture()
        let context = container.mainContext
        let coordinator = SelectionTranslationCoordinator(preview: preview)
        let service = CountingAnalysisService()
        coordinator.saveToDictionary(context: context, service: service)
        coordinator.saveToDictionary(context: context, service: service)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DictionaryEntry>()), 0)
        try await waitUntilFinished(coordinator)
        coordinator.saveToDictionary(context: context, service: service)
        let entries = try context.fetch(FetchDescriptor<DictionaryEntry>())
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.text, preview.selectedText)
        XCTAssertEqual(entry.translationText, "молния")
        XCTAssertEqual(entry.translationOrigin, .openAI)
        XCTAssertEqual(entry.translationStatus, .ready)
        XCTAssertEqual(entry.contextSelectedTranslationText, entry.translationText)
        XCTAssertEqual(entry.contextTranslationText, "zamek — zamek — молния")
        XCTAssertEqual(entry.sourceTrackID, "track-2")
        XCTAssertEqual(entry.audioStart, 3)
        XCTAssertEqual(entry.audioEnd, 5)
        XCTAssertEqual(entry.segmentIndex, 4)
        XCTAssertEqual(entry.contextText, preview.context?.text)
        XCTAssertEqual(entry.localSourceItemID, preview.sourceItemID)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        let exported = try DictionaryTransferService.export(entries: entries, includeContext: true)
        XCTAssertEqual(try DictionaryTransferService.decode(exported.data).entries.first?.translation.origin, "openAI")
    }

    func testPreviewCanBeClosedAndReopenedForSavingWithoutAnotherRequest() async throws {
        let (container, _, preview) = try fixture()
        let cache = SelectionTranslationCache()
        let coordinator = cache.coordinator(for: preview)
        let service = CountingAnalysisService()
        coordinator.start(service: service)
        XCTAssertTrue(cache.coordinator(for: preview) === coordinator,
                      "Sheet reevaluation must retain an in-flight coordinator")
        try await waitUntilFinished(coordinator)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DictionaryEntry>()), 0)
        coordinator.dismiss()
        let reopened = cache.coordinator(for: preview)
        XCTAssertTrue(reopened === coordinator)
        reopened.saveToDictionary(context: container.mainContext, service: service)
        XCTAssertNotNil(reopened.savedEntryID)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        let differentContext = SelectionTranslationPreview(
            selectedText: "zamek", sourceLanguageCode: "pl",
            context: .init(text: "Stary zamek.", selection: NSRange(location: 6, length: 5)),
            sourceItemID: preview.sourceItemID, sourceTitle: preview.sourceTitle, audioRange: nil)
        XCTAssertFalse(cache.coordinator(for: differentContext) === coordinator)
    }

    func testFailureShowsErrorAndDoesNotSaveThenExplicitRetryCanSave() async throws {
        let (container, _, preview) = try fixture()
        let coordinator = SelectionTranslationCoordinator(preview: preview)
        coordinator.saveToDictionary(context: container.mainContext,
                                     service: CountingAnalysisService(error: .invalidOutput))
        try await waitUntilFinished(coordinator)
        XCTAssertEqual(coordinator.errorMessage, ContextAnalysisError.invalidOutput.userMessage)
        XCTAssertFalse(coordinator.isSaving)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DictionaryEntry>()), 0)
        coordinator.saveToDictionary(context: container.mainContext, service: CountingAnalysisService())
        try await waitUntilFinished(coordinator)
        XCTAssertNotNil(coordinator.savedEntryID)
    }

    func testDismissedSaveCannotPersistLateResult() throws {
        let (container, _, preview) = try fixture()
        let coordinator = SelectionTranslationCoordinator(preview: preview)
        coordinator.saveToDictionary(context: container.mainContext, service: CountingAnalysisService())
        let pending = try XCTUnwrap(coordinator.currentRequest())
        coordinator.dismiss()
        coordinator.acceptResult(token: pending.token, previewID: preview.id,
                                 result: .init(directTranslation: "late", contextExplanation: "late"))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DictionaryEntry>()), 0)
        XCTAssertFalse(coordinator.isSaving)
    }

    func testAppDeclaresBackgroundAudio() {
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio"))
    }
}

final class DiagnosticLogTests: XCTestCase {
    func testLogSurvivesReopenAndExportsBoundedMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "logs.json")
        let log = DiagnosticLog(fileURL: url, maximumEntries: 2)
        await log.record(.init(event: "first", error: .timeout))
        await log.record(.init(event: "second", error: .decodingFailure, model: .mini, httpStatus: 200))
        await log.record(.init(event: "third", error: .invalidOutput))
        let reopened = DiagnosticLog(fileURL: url)
        let data = try await reopened.export()
        let entries = try JSONDecoder().decode([DiagnosticLog.Entry].self, from: data)
        XCTAssertEqual(entries.map(\.event), ["second", "third"])
        XCTAssertEqual(entries.first?.error, .decodingFailure)
        XCTAssertEqual(entries.first?.httpStatus, 200)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let allowed = Set(["timestamp", "event", "error", "model", "requestID", "httpStatus", "promptVersion"])
        XCTAssertTrue(objects.allSatisfy { Set($0.keys).isSubset(of: allowed) })
    }
}
