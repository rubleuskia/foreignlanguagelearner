import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class LegacyTranslationCompatibilityTests: XCTestCase {
    func testHistoricalDefinitionsDecodeWithoutLookupServiceOrMorphologyDatabase() throws {
        let json = #"""
        {"requestedWord":"domu","headword":"dom","resolvedFromForm":"domu",
         "partOfSpeech":"rzeczownik","meanings":[{"id":"1.1","definition":"budynek",
         "examples":["Wróciłem do domu."],"usageLabels":[]}],
         "sourceURL":"https://pl.wiktionary.org/wiki/dom?oldid=123","revisionID":123,
         "fetchedAt":"2026-09-17T12:00:00Z"}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(PolishDictionaryResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.resolvedFromForm, "domu")
        XCTAssertEqual(result.meanings.first?.examples, ["Wróciłem do domu."])
        XCTAssertEqual(result.revisionID, 123)
        XCTAssertNil(result.formOfLemma, "Older cached results predate the optional lemma reference")
    }

    func testHistoricalDiagnosticsRemainReadableWithoutRewritingTheirFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "polish-definition-errors.json")
        let data = Data(#"""
        [{"timestamp":"2026-09-17T12:00:00Z","operation":"lookup","word":"żółć",
          "errorType":"URLError","errorDomain":"NSURLErrorDomain","errorCode":-1009,
          "message":"Offline"}]
        """#.utf8)
        try data.write(to: fileURL)
        let log = PolishLookupDiagnosticLog(fileURL: fileURL)
        XCTAssertEqual(log.events().map(\.word), ["żółć"])
        XCTAssertEqual(log.events().map(\.errorCode), [-1009])
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        try Data("invalid".utf8).write(to: fileURL)
        XCTAssertTrue(log.events().isEmpty)
        try FileManager.default.removeItem(at: fileURL)
        XCTAssertTrue(log.events().isEmpty)
    }

    @MainActor func testCloudContextRefreshPreservesSavedTranslationAndLegacyWordHelp() async throws {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
            mediaFilename: "story.m4a", transcriptFilename: "story.srt", duration: 10, segments: [])
        let text = "Zepsuł się zamek w kurtce."
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: 0,
            context: .init(text: text, selection: (text as NSString).range(of: "zamek")))
        entry.translationText = "замок"
        entry.translationOrigin = .manual
        entry.translationStatus = .ready
        entry.wordHelpItems = [.init(sourceText: "zamek", translationText: "замок", isGrammarWord: false)]
        let legacyItems = entry.wordHelpItems
        container.mainContext.insert(item)
        container.mainContext.insert(entry)
        try container.mainContext.save()
        let coordinator = ContextualTranslationCoordinator()
        coordinator.translateContext(for: entry, context: container.mainContext,
            service: FixedContextAnalysisService())
        for _ in 0..<100 where coordinator.status == .translatingContext {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertEqual(entry.contextSelectedTranslationText, "молния")
        XCTAssertEqual(entry.contextTranslationText, "zamek — zamek — молния")
        XCTAssertEqual(entry.translationText, "замок")
        XCTAssertEqual(entry.translationOrigin, .manual)
        XCTAssertEqual(entry.wordHelpItems, legacyItems)
    }
}

private struct FixedContextAnalysisService: ContextAnalysisServing {
    func analyze(_ request: ContextAnalysisRequest) async throws -> ContextualPhraseResult {
        .init(directTranslation: "молния", contextExplanation: "zamek — zamek — молния")
    }
}
