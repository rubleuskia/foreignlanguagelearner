import XCTest
import SwiftData
@testable import ForeignLanguageLearner

final class DictionaryFeatureTests: XCTestCase {
    func testSameLanguagePairInvalidatesTranslationConfiguration() {
        let first = TranslationConfiguration.next(previous: nil, source: "pl", target: "ru")
        let second = TranslationConfiguration.next(previous: first, source: "pl", target: "ru")

        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThan(second.version, first.version)
        XCTAssertEqual(second.source, first.source)
        XCTAssertEqual(second.target, first.target)
    }

    func testLearningLevelAdjustmentIsBounded() {
        XCTAssertEqual(LearningLevel.adjusted(1, correct: false), 1)
        XCTAssertEqual(LearningLevel.adjusted(1, correct: true), 2)
        XCTAssertEqual(LearningLevel.adjusted(3, correct: true), 4)
        XCTAssertEqual(LearningLevel.adjusted(4, correct: true), 4)
        XCTAssertEqual(LearningLevel.adjusted(4, correct: false), 3)
    }

    func testWrongLearningAnswerMovesEntryToEndUntilAnsweredCorrectly() {
        let first = UUID()
        let second = UUID()
        var queue = [first, second]
        var index = 0

        index = LearningQueue.advance(&queue, from: index, correct: false)
        XCTAssertEqual(queue, [first, second, first])
        XCTAssertEqual(index, 1)

        index = LearningQueue.advance(&queue, from: index, correct: true)
        index = LearningQueue.advance(&queue, from: index, correct: true)
        XCTAssertEqual(index, queue.count)
        XCTAssertEqual(queue.filter { $0 == first }.count, 2)
    }

    func testPartialSelectionExpandsToUnicodeWordBoundaries() throws {
        let text = "On powiedział: Zepsuł się zamek 🌍."
        let partial = (text as NSString).range(of: "epsuł si")

        let expanded = WordSelectionExpander.expandedRange(in: text, selection: partial)

        XCTAssertEqual((text as NSString).substring(with: expanded), "Zepsuł się")
    }

    func testSelectionExpansionPreservesAdjacentPunctuation() throws {
        let text = "(dzień dobry), świecie!"
        let partial = (text as NSString).range(of: "zień dobr")

        let expanded = WordSelectionExpander.expandedRange(in: text, selection: partial)

        XCTAssertEqual((text as NSString).substring(with: expanded), "dzień dobry")
    }

    func testContextSentenceExtractionKeepsSelectionInContainingSentence() throws {
        let text = "Pierwsze zdanie.  Zepsuł się zamek w kurtce! Ostatnie zdanie."
        let selection = (text as NSString).range(of: "zamek")

        let sentence = try XCTUnwrap(ContextSentenceExtractor.sentence(text: text, selection: selection))

        XCTAssertEqual(sentence.text, "Zepsuł się zamek w kurtce!")
        XCTAssertEqual((sentence.text as NSString).substring(with: sentence.selection), "zamek")
    }

    func testWordBreakdownMarksCommonGrammarWordsButKeepsSelectedShortWordVisible() {
        let tokens = WordBreakdownBuilder.tokens(in: "Ja idę do domu i czytam.", selectedText: "do",
                                                 languageCode: "pl")

        XCTAssertEqual(tokens.map(\.text), ["Ja", "idę", "do", "domu", "i", "czytam"])
        XCTAssertFalse(tokens.first(where: { $0.text == "do" })?.isGrammarWord ?? true,
                       "The selected expression is never hidden as a grammar word")
        XCTAssertTrue(tokens.first(where: { $0.text == "i" })?.isGrammarWord ?? false)
    }

    func testQualityConfigurationInvalidatesForRepeatedRequests() {
        let first = QualityTranslationConfiguration.next(previous: nil, source: "pl", target: "ru")
        let second = QualityTranslationConfiguration.next(previous: first, source: "pl", target: "ru")

        XCTAssertGreaterThan(second.version, first.version)
        if #available(iOS 26.4, *) {
            XCTAssertEqual(second.preferredStrategy, .highFidelity)
        }
    }

    @MainActor func testNewDictionaryEntryUsesBookLanguageAndStartsPendingAtLevelOne() throws {
        let item = LearningItem(id: UUID(), title: "Polish story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [], sourceLanguageCode: "pl")
        let selection = SelectionContext(text: "To jest dzień dobry.", selection: NSRange(location: 8, length: 11))
        let entry = DictionaryEntry(text: " dzień   dobry ", item: item, segmentIndex: 0, context: selection)

        XCTAssertEqual(entry.text, "dzień dobry")
        XCTAssertEqual(entry.sourceLanguageCode, "pl")
        XCTAssertEqual(entry.targetLanguageCode, "ru")
        XCTAssertEqual(entry.translationStatus, .pending)
        XCTAssertEqual(entry.learningLevel, 1)
        XCTAssertFalse(entry.isLearningEligible)

        entry.translationText = "добрый день"
        entry.translationStatus = .ready
        entry.translationOrigin = .manual
        XCTAssertTrue(entry.isLearningEligible)
        entry.learningLevel = 4
        XCTAssertFalse(entry.isLearningEligible)
    }

    @MainActor func testDictionaryJSONRoundTripAndTranslationOnlyImport() throws {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [], sourceLanguageCode: "pl")
        let entry = DictionaryEntry(text: "dzień dobry", item: item, segmentIndex: 0,
                                    context: SelectionContext(text: "Powiedział: dzień dobry.",
                                                              selection: NSRange(location: 12, length: 11)))
        entry.translationText = "добрый день"
        entry.translationStatus = .ready
        entry.translationOrigin = .manual
        entry.learningLevel = 3
        context.insert(item)
        context.insert(entry)
        try context.save()

        let file = try DictionaryTransferService.export(entries: [entry], includeContext: true)
        let decoded = try DictionaryTransferService.decode(file.data)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries[0].translation.baseText, "добрый день")
        XCTAssertEqual(decoded.entries[0].source.context?.selectionUTF16.location, 12)

        let source = decoded.entries[0]
        let improved = DictionaryTransferDocument.Entry(
            id: source.id, text: source.text, sourceLanguage: source.sourceLanguage,
            targetLanguage: source.targetLanguage,
            translation: .init(text: "добрый день!", baseText: source.translation.baseText,
                               origin: source.translation.origin, updatedAt: source.translation.updatedAt),
            learningLevel: 1, createdAt: source.createdAt, source: source.source
        )
        let document = DictionaryTransferDocument(format: decoded.format, schemaVersion: decoded.schemaVersion,
                                                  exportedAt: .now, entries: [improved])
        let preview = DictionaryTransferService.preview(document: document, mode: .translations, existing: [entry])
        XCTAssertEqual(preview.translationChanges, 1)
        XCTAssertEqual(preview.conflicts, 0)
        _ = try DictionaryTransferService.apply(preview, context: context)

        XCTAssertEqual(entry.translationText, "добрый день!")
        XCTAssertEqual(entry.translationOrigin, .imported)
        XCTAssertEqual(entry.learningLevel, 3, "Translation-only imports preserve learning progress")
    }

    @MainActor func testDictionaryExportIncludesPolishLookupDiagnostics() throws {
        let event = PolishLookupDiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: 123), operation: "lookup", word: "żółć",
            preferredLemma: nil, entryID: UUID(), errorType: "URLError",
            errorDomain: NSURLErrorDomain, errorCode: -1009, message: "Offline"
        )

        let file = try DictionaryTransferService.export(entries: [], includeContext: false,
                                                        diagnosticEvents: [event])
        let decoded = try DictionaryTransferService.decode(file.data)

        XCTAssertEqual(decoded.diagnostics?.polishDefinitionErrors, [event])
        XCTAssertFalse(decoded.diagnostics?.appVersion.isEmpty ?? true)
        XCTAssertFalse(decoded.diagnostics?.operatingSystem.isEmpty ?? true)
    }

    @MainActor func testExportWritesExplicitNullsForLLMRoundTrip() throws {
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [])
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: nil)
        let file = try DictionaryTransferService.export(entries: [entry], includeContext: true)
        let json = try XCTUnwrap(String(data: file.data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"text\" : null"))
        XCTAssertTrue(json.contains("\"baseText\" : null"))
        XCTAssertTrue(json.contains("\"context\" : null"))
        XCTAssertNoThrow(try DictionaryTransferService.decode(file.data))
    }

    @MainActor func testContextAnalysisPersistsWithDictionaryEntry() throws {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [])
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: 0,
                                    context: SelectionContext(text: "Zepsuł się zamek w kurtce.",
                                                              selection: NSRange(location: 10, length: 5)))
        entry.contextSelectedTranslationText = "молния"
        entry.contextTranslationText = "На куртке сломалась молния."
        let dictionaryResult = PolishDictionaryResult(
            requestedWord: "kurtce", headword: "kurtka", resolvedFromForm: "kurtce",
            partOfSpeech: "rzeczownik", meanings: [
                .init(id: "1.1", definition: "część ubrania", examples: ["Założyła kurtkę."], usageLabels: [])
            ], sourceURL: "https://pl.wiktionary.org/wiki/kurtka", revisionID: 1,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        entry.wordHelpItems = [.init(sourceText: "kurtce", translationText: "куртке",
                                     isGrammarWord: false, polishDictionaryResult: dictionaryResult)]
        entry.selectedSenseText = "молния на одежде"
        entry.userNote = "Не замок-здание."
        context.insert(item)
        context.insert(entry)
        try context.save()

        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<DictionaryEntry>()).first)
        XCTAssertEqual(saved.contextSelectedTranslationText, "молния")
        XCTAssertEqual(saved.contextTranslationText, "На куртке сломалась молния.")
        XCTAssertEqual(saved.wordHelpItems.first?.translationText, "куртке")
        XCTAssertEqual(saved.wordHelpItems.first?.polishDictionaryResult, dictionaryResult)
        XCTAssertEqual(saved.selectedSenseText, "молния на одежде")
        XCTAssertEqual(saved.userNote, "Не замок-здание.")
    }

    @MainActor func testLanguageChangeInvalidatesGeneratedAnalysisButPreservesUserNotes() {
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [])
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: nil)
        entry.contextSelectedTranslationText = "молния"
        entry.contextTranslationText = "На куртке сломалась молния."
        entry.wordHelpItems = [.init(sourceText: "zamek", translationText: "молния",
                                     isGrammarWord: false)]
        entry.selectedSenseText = "молния"
        entry.userNote = "Clothing meaning"

        entry.invalidateGeneratedContextAnalysis()

        XCTAssertNil(entry.contextSelectedTranslationText)
        XCTAssertNil(entry.contextTranslationText)
        XCTAssertTrue(entry.wordHelpItems.isEmpty)
        XCTAssertEqual(entry.selectedSenseText, "молния")
        XCTAssertEqual(entry.userNote, "Clothing meaning")
        XCTAssertEqual(entry.contextAnalysisRevision, 1)
    }
}
