import SwiftData
import SwiftUI
import XCTest
@testable import ForeignLanguageLearner

private actor SentenceAnalysisFixture: ContextAnalysisServing {
    private(set) var requests: [ContextAnalysisRequest] = []
    let fail: Bool
    private var failuresRemaining: Int
    init(fail: Bool = false, failuresRemaining: Int = 0) { self.fail = fail; self.failuresRemaining = failuresRemaining }
    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult {
        requests.append(request)
        if fail { throw ContextAnalysisError.networkUnavailable }
        if failuresRemaining > 0 { failuresRemaining -= 1; throw ContextAnalysisError.networkUnavailable }
        return .init(directTranslation: "Перевод: \(request.selectedText)", contextExplanation: "")
    }
}

/// Deliberately ignores cancellation to exercise the late-provider-response fence.
private actor DeferredSentenceFixture: ContextAnalysisServing {
    private var pending: [CheckedContinuation<ContextualPhraseResult, Error>] = []
    private(set) var calls = 0
    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult {
        calls += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish() {
        let waiting = pending; pending = []
        for value in waiting { value.resume(returning: .init(directTranslation: "Готово", contextExplanation: "")) }
    }
}

@MainActor final class BookAutoTranslationTests: XCTestCase {
    private func fixture(commitSave: @escaping (ModelContext) throws -> Void = { try $0.save() }) async throws
        -> (ModelContainer, LearningItem, ReadingVocabularyStore) {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
            ReadVocabularyWord.self, ReadVocabularyBatch.self, UserActivityEvent.self,
            SentenceTranslation.self, BookSentenceTranslation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio", mediaFilename: "",
                                transcriptFilename: "story.txt", duration: 0, segments: [])
        item.sourceLanguageCode = "en"; item.readingVocabularyMigrationVersion = 1
        container.mainContext.insert(item); try container.mainContext.save()
        let vocabulary = ReadingVocabularyStore(commitSave: commitSave)
        await vocabulary.start(context: container.mainContext)
        XCTAssertTrue(vocabulary.ready)
        return (container, item, vocabulary)
    }

    private func document(_ text: String) -> TranscriptDocument {
        .init(segments: [.init(start: nil, end: nil, text: text)])
    }

    private func show(_ coordinator: BookAutoTranslationCoordinator, text: String, range: NSRange? = nil,
                      item: LearningItem, vocabulary: ReadingVocabularyStore, context: ModelContext,
                      service: any ContextAnalysisServing, scope: String = "full") {
        coordinator.pageVisible(range ?? NSRange(location: 0, length: text.utf16.count),
            document: document(text), item: item, scope: scope,
            vocabulary: vocabulary, context: context, service: service)
    }

    private func waitFor(_ predicate: @MainActor () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not complete", line: line)
    }

    func testPageSnapshotTranslatesEverySentenceAndRetainsYellowUntilLeaving() async throws {
        let (container, item, vocabulary) = try await fixture()
        let coordinator = BookAutoTranslationCoordinator(), service = SentenceAnalysisFixture()
        let text = "Cats run. Cats sleep."
        show(coordinator, text: text, item: item, vocabulary: vocabulary, context: container.mainContext, service: service)
        XCTAssertFalse(coordinator.enabled)
        coordinator.setEnabled(true)
        XCTAssertFalse(coordinator.requestManualTurn())
        try await waitFor { coordinator.pendingCount == 0 }
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.selectedText), ["Cats run.", "Cats sleep."])
        XCTAssertTrue(requests.allSatisfy { $0.translationOnly && $0.wordsToExplain.isEmpty })
        XCTAssertEqual(vocabulary.forms(for: "en"), ["cats", "run", "sleep"])
        XCTAssertEqual(coordinator.retainedNewForms, ["cats", "run", "sleep"])
        XCTAssertEqual(coordinator.translations.count, 2)
        XCTAssertTrue(coordinator.requestManualTurn())
        XCTAssertFalse(item.isBookCompleted)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DictionaryEntry>()), 0)
        coordinator.setEnabled(false)
        XCTAssertEqual(coordinator.retainedNewForms.count, 3, "Toggle-off must not erase this visit's highlights")
        show(coordinator, text: text, range: NSRange(location: 0, length: 9), item: item,
             vocabulary: vocabulary, context: container.mainContext, service: service)
        XCTAssertTrue(coordinator.retainedNewForms.isEmpty)
        XCTAssertEqual(coordinator.translations.count, 2)
    }

    func testCacheReusesAcrossBooksButPreservesWhitespacePunctuationAndLanguages() async throws {
        let (container, item, vocabulary) = try await fixture()
        let first = BookAutoTranslationCoordinator(), service = SentenceAnalysisFixture()
        show(first, text: "Cats run.", item: item, vocabulary: vocabulary, context: container.mainContext, service: service)
        first.setEnabled(true)
        try await waitFor { first.pendingCount == 0 }
        first.close()
        let other = LearningItem(id: UUID(), title: "Other", mediaKind: "audio", mediaFilename: "",
                                 transcriptFilename: "other.txt", duration: 0, segments: [])
        other.sourceLanguageCode = "en"; other.readingVocabularyMigrationVersion = 1
        container.mainContext.insert(other); try container.mainContext.save()
        // A fresh vocabulary snapshot models reuse with a new/independently restored knowledge set.
        let fresh = ReadingVocabularyStore()
        await fresh.start(context: container.mainContext)
        for batch in try container.mainContext.fetch(FetchDescriptor<ReadVocabularyBatch>()) { container.mainContext.delete(batch) }
        try container.mainContext.save()
        try fresh.reload(context: container.mainContext)
        let cached = SentenceTranslation.key(text: "CATS RUN.", sourceLanguage: "en", targetLanguage: "ru")
        XCTAssertEqual(cached, SentenceTranslation.key(text: "Cats run.", sourceLanguage: "en", targetLanguage: "ru"))
        XCTAssertNotEqual(cached, SentenceTranslation.key(text: "Cats  run.", sourceLanguage: "en", targetLanguage: "ru"))
        XCTAssertNotEqual(cached, SentenceTranslation.key(text: "Cats run!", sourceLanguage: "en", targetLanguage: "ru"))
        XCTAssertNotEqual(cached, SentenceTranslation.key(text: "Cats run.", sourceLanguage: "pl", targetLanguage: "ru"))
        // Seed another occurrence with one new word, then reuse it in another scope.
        let second = BookAutoTranslationCoordinator()
        show(second, text: "CATS RUN.", item: other, vocabulary: fresh, context: container.mainContext, service: service)
        second.setEnabled(true)
        try await waitFor { second.pendingCount == 0 }
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(second.translations.count, 1)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<BookSentenceTranslation>()), 2)
        second.close()
        let reopened = BookAutoTranslationCoordinator()
        show(reopened, text: "Cats run.", range: NSRange(location: 0, length: 4), item: item,
             vocabulary: vocabulary, context: container.mainContext, service: service)
        XCTAssertEqual(reopened.translations.count, 1)
        XCTAssertTrue(reopened.retainedNewForms.isEmpty)
        show(reopened, text: "Changed text.", item: item, vocabulary: vocabulary, context: container.mainContext, service: service)
        XCTAssertTrue(reopened.translations.isEmpty, "Old offsets must not attach to replaced text")
        reopened.close()
    }

    func testCancellationRejectsLateResultAndUnblocksManualTurns() async throws {
        let (container, item, vocabulary) = try await fixture()
        let coordinator = BookAutoTranslationCoordinator(), service = DeferredSentenceFixture()
        show(coordinator, text: "Cats run.", item: item, vocabulary: vocabulary, context: container.mainContext, service: service)
        coordinator.setEnabled(true)
        for _ in 0..<100 {
            if await service.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(coordinator.blocksManualTurn)
        coordinator.setEnabled(false)
        XCTAssertTrue(coordinator.requestManualTurn())
        await service.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(coordinator.translations.isEmpty)
        XCTAssertTrue(vocabulary.forms(for: "en").isEmpty)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<SentenceTranslation>()), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<BookSentenceTranslation>()), 0)
    }

    func testFailureReleasesLockAndExplicitRetryUsesOriginalSentenceSet() async throws {
        let (container, item, vocabulary) = try await fixture()
        let coordinator = BookAutoTranslationCoordinator()
        let service = SentenceAnalysisFixture(failuresRemaining: 1)
        show(coordinator, text: "Cats. Cats!", item: item, vocabulary: vocabulary, context: container.mainContext,
             service: service)
        coordinator.setEnabled(true)
        try await waitFor { coordinator.pendingCount == 0 }
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertTrue(coordinator.requestManualTurn())
        XCTAssertEqual(vocabulary.forms(for: "en"), ["cats"])
        XCTAssertEqual(coordinator.translations.count, 1)
        coordinator.retry()
        try await waitFor { coordinator.pendingCount == 0 }
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(coordinator.translations.count, 2)
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.selectedText), ["Cats.", "Cats!", "Cats."])
        coordinator.setEnabled(false)
    }

    func testPersistenceFailureRollsBackCacheAnchorAndLearnedWordsTogether() async throws {
        let (container, item, vocabulary) = try await fixture(commitSave: { _ in throw ContextAnalysisError.persistence })
        let coordinator = BookAutoTranslationCoordinator()
        show(coordinator, text: "Cats run.", item: item, vocabulary: vocabulary, context: container.mainContext, service: SentenceAnalysisFixture())
        coordinator.setEnabled(true)
        try await waitFor { coordinator.pendingCount == 0 }
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertTrue(vocabulary.forms(for: "en").isEmpty)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<SentenceTranslation>()), 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<BookSentenceTranslation>()), 0)
        XCTAssertEqual(try ReadingKnowledge.forms(context: container.mainContext)["en"] ?? [], [])
        coordinator.setEnabled(false)
    }

    func testAudioCanAdvanceWhileOldPageRequestFinishesWithItsOriginalAnchor() async throws {
        let (container, item, vocabulary) = try await fixture()
        let coordinator = BookAutoTranslationCoordinator(), service = DeferredSentenceFixture()
        let text = "Cats run. Dogs sleep."
        show(coordinator, text: text, range: NSRange(location: 0, length: 9), item: item,
             vocabulary: vocabulary, context: container.mainContext, service: service)
        coordinator.setEnabled(true)
        for _ in 0..<100 {
            if await service.calls == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Audio does not call requestManualTurn; it announces its newly visible page.
        show(coordinator, text: text, range: NSRange(location: 10, length: 11), item: item,
             vocabulary: vocabulary, context: container.mainContext, service: service)
        await service.finish()
        for _ in 0..<100 {
            if await service.calls == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await service.finish()
        try await waitFor { coordinator.pendingCount == 0 }
        XCTAssertEqual(coordinator.translations.map(\.range), [NSRange(location: 0, length: 9), NSRange(location: 10, length: 11)])
        XCTAssertEqual(coordinator.retainedNewForms, ["dogs", "sleep"])
        coordinator.setEnabled(false)
    }

    func testCachedPreviewSavesWholeSentenceWithoutCallingService() async throws {
        let (container, item, _) = try await fixture()
        let service = SentenceAnalysisFixture()
        var preview = SelectionTranslationPreview(selectedText: "Cats run.", sourceLanguageCode: "en",
            context: .init(text: "Cats run.", selection: NSRange(location: 0, length: 9)),
            sourceItemID: item.id, sourceTitle: item.title, audioRange: nil)
        preview.cachedTranslation = "Коты бегут."
        let coordinator = SelectionTranslationCoordinator(preview: preview)
        coordinator.start(service: service)
        coordinator.saveToDictionary(context: container.mainContext, service: service)
        let entries = try container.mainContext.fetch(FetchDescriptor<DictionaryEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "Cats run.")
        XCTAssertEqual(entries.first?.translationText, "Коты бегут.")
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSessionStateIsPerBookAndVerticalModeDisablesIt() async throws {
        let itemID = UUID()
        let first = BookAutoTranslationCoordinator()
        first.open(itemID: itemID); first.setEnabled(true); first.close()
        let reopened = BookAutoTranslationCoordinator()
        reopened.open(itemID: itemID)
        XCTAssertTrue(reopened.enabled)
        let another = BookAutoTranslationCoordinator()
        another.open(itemID: UUID())
        XCTAssertFalse(another.enabled)
        reopened.leavePages()
        reopened.close(); reopened.open(itemID: itemID)
        XCTAssertFalse(reopened.enabled)
    }

    func testFullSentenceModeRetainsLongTextWithoutChangingOrdinarySelectionLimit() throws {
        let text = String(repeating: "hello ", count: 100) + "world."
        let selection = SelectionContext(text: text, selection: NSRange(location: 0, length: text.utf16.count))
        XCTAssertThrowsError(try ContextAnalysisRequestBuilder.build(.init(subject: .preview(UUID()), revision: 1,
            expectedSelectedText: text, context: selection, sourceLanguage: "en", targetLanguage: "ru", promptVersion: "test")))
        let request = try ContextAnalysisRequestBuilder.build(.init(subject: .preview(UUID()), revision: 1,
            expectedSelectedText: text, context: selection, sourceLanguage: "en", targetLanguage: "ru",
            promptVersion: "test", translationOnly: true))
        XCTAssertEqual(request.selectedText, text)
        XCTAssertEqual(try ContextAnalysisRequestBuilder.reducing(request).selectedText, text)
        XCTAssertTrue(request.wordsToExplain.isEmpty)
        try CloudTranslationPayload(request).validate(kind: "context")
    }

    func testRepaginationKeepsVisitHighlightsAndDoesNotRetranslateSavedSentences() async throws {
        let (container, item, vocabulary) = try await fixture()
        let coordinator = BookAutoTranslationCoordinator(), service = SentenceAnalysisFixture()
        let text = "Cats run. Dogs sleep."
        show(coordinator, text: text, range: NSRange(location: 0, length: 9), item: item,
             vocabulary: vocabulary, context: container.mainContext, service: service)
        coordinator.setEnabled(true)
        try await waitFor { coordinator.pendingCount == 0 }
        coordinator.pageVisible(NSRange(location: 0, length: text.utf16.count), document: document(text), item: item,
            scope: "full", vocabulary: vocabulary, context: container.mainContext, service: service, newVisit: false)
        try await waitFor { coordinator.pendingCount == 0 }
        XCTAssertEqual(coordinator.retainedNewForms, ["cats", "run", "dogs", "sleep"])
        let requests = await service.requests
        XCTAssertEqual(requests.map(\.selectedText), ["Cats run.", "Dogs sleep."])
        coordinator.setEnabled(false)
    }

    func testTimedCueBreaksDoNotSplitSentencesAcrossPages() async throws {
        let (container, item, vocabulary) = try await fixture()
        let coordinator = BookAutoTranslationCoordinator(), service = SentenceAnalysisFixture()
        let transcript = TranscriptDocument(segments: [
            .init(start: 0, end: 1, text: "The cat"),
            .init(start: 1, end: 2, text: "runs quickly.")])
        coordinator.pageVisible(transcript.ranges[0], document: transcript, item: item, scope: "track:one",
            vocabulary: vocabulary, context: container.mainContext, service: service)
        coordinator.setEnabled(true)
        try await waitFor { coordinator.pendingCount == 0 }
        let requests = await service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.selectedText, transcript.text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(vocabulary.forms(for: "en"), ["the", "cat", "runs", "quickly"])
        coordinator.pageVisible(transcript.ranges[1], document: transcript, item: item, scope: "track:one",
            vocabulary: vocabulary, context: container.mainContext, service: service)
        XCTAssertTrue(coordinator.retainedNewForms.isEmpty)
        XCTAssertEqual(coordinator.translations.count, 1)
        let afterTurn = await service.requests
        XCTAssertEqual(afterTurn.count, 1)
        coordinator.setEnabled(false)
    }

    func testExistingStoreUpgradesAndSavedAnchorsSurviveContainerReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "reader.store"), itemID = UUID()
        let text = "Cats run.", range = NSRange(location: 0, length: 9)
        do {
            let schema = Schema([LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self,
                                 ReadVocabularyBatch.self, UserActivityEvent.self])
            let legacy = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let item = LearningItem(id: itemID, title: "Existing book", mediaKind: "audio", mediaFilename: "",
                                    transcriptFilename: "book.txt", duration: 0, segments: [])
            item.sourceLanguageCode = "en"; item.readingVocabularyMigrationVersion = 1
            item.readingCharacterOffset = 41
            legacy.mainContext.insert(item); try legacy.mainContext.save()
        }
        let schema = Schema([LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self,
            ReadVocabularyBatch.self, UserActivityEvent.self, SentenceTranslation.self, BookSentenceTranslation.self])
        do {
            let upgraded = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let item = try XCTUnwrap(upgraded.mainContext.fetch(FetchDescriptor<LearningItem>()).first)
            XCTAssertEqual(item.readingCharacterOffset, 41)
            let cached = SentenceTranslation(text: text, sourceLanguage: "en", targetLanguage: "ru", translation: "Коты бегут.")
            upgraded.mainContext.insert(cached)
            upgraded.mainContext.insert(BookSentenceTranslation(itemID: itemID, scope: "full",
                documentDigest: SentenceTranslation.digest(text), range: range, translationKey: cached.key))
            ReadingKnowledge.insert(try ReadingKnowledge.encode(["cats", "run"]), language: "en", context: upgraded.mainContext)
            try upgraded.mainContext.save()
        }
        let reopened = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let item = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<LearningItem>()).first)
        let vocabulary = ReadingVocabularyStore()
        await vocabulary.start(context: reopened.mainContext)
        let coordinator = BookAutoTranslationCoordinator()
        show(coordinator, text: text, range: NSRange(location: 0, length: 4), item: item,
             vocabulary: vocabulary, context: reopened.mainContext, service: SentenceAnalysisFixture())
        XCTAssertFalse(coordinator.enabled)
        XCTAssertEqual(coordinator.translations.first?.translation, "Коты бегут.")
        XCTAssertEqual(coordinator.translations.first?.range, range)
        XCTAssertTrue(coordinator.retainedNewForms.isEmpty)
        XCTAssertEqual(vocabulary.forms(for: "en"), ["cats", "run"])
    }
}
