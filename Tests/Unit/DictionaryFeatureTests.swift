import XCTest
import SwiftData
@testable import ForeignLanguageLearner

final class DictionaryFeatureTests: XCTestCase {
    func testLearningLevelAdjustmentIsBounded() {
        XCTAssertEqual(LearningLevel.adjusted(1, correct: false), 1)
        XCTAssertEqual(LearningLevel.adjusted(1, correct: true), 2)
        XCTAssertEqual(LearningLevel.adjusted(3, correct: true), 4)
        XCTAssertEqual(LearningLevel.adjusted(4, correct: true), 4)
        XCTAssertEqual(LearningLevel.adjusted(4, correct: false), 3)
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
}
