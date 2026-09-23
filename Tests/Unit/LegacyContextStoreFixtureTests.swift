import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class LegacyContextStoreFixtureTests: XCTestCase {
    @MainActor func testPreMigrationFixtureReopensWithAllSeededValues() throws {
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures/FoundationModelsLegacyStore", directoryHint: .isDirectory)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "legacy-context-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        for source in try FileManager.default.contentsOfDirectory(at: fixtureDirectory,
                                                                  includingPropertiesForKeys: nil) {
            guard source.lastPathComponent.hasPrefix("LegacyContext.store") else { continue }
            try FileManager.default.copyItem(at: source,
                                             to: temporaryDirectory.appending(path: source.lastPathComponent))
        }

        let store = temporaryDirectory.appending(path: "LegacyContext.store")
        do {
            let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                                               configurations: ModelConfiguration(url: store))
            let item = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<LearningItem>()).first)
            let entry = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<DictionaryEntry>()).first)

            XCTAssertEqual(item.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
            XCTAssertEqual(item.lastPosition, 37)
            XCTAssertEqual(item.parts.first?.lastPosition, 37)
            XCTAssertEqual(item.lastTrackID, "chapter-1")
            XCTAssertEqual(item.tracks.first?.lastPosition, 37)

            XCTAssertEqual(entry.id, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
            XCTAssertEqual(entry.translationText, "молния")
            XCTAssertEqual(entry.translationOrigin, .manual)
            XCTAssertEqual(entry.translationStatus, .ready)
            XCTAssertEqual(entry.translationRevision, 4)
            XCTAssertEqual(entry.learningLevel, 3)
            XCTAssertEqual(entry.contextText, "Zepsuł się zamek w kurtce.")
            XCTAssertEqual(entry.contextSelectionLocation, 11)
            XCTAssertEqual(entry.contextSelectionLength, 5)
            XCTAssertEqual(entry.contextSelectedTranslationText, "молния")
            XCTAssertEqual(entry.contextTranslationText, "На куртке сломалась молния.")
            XCTAssertEqual(entry.contextAnalysisRevision, 6)
            XCTAssertEqual(entry.wordHelpItems.first?.translationText, "куртке")
            XCTAssertEqual(entry.wordHelpItems.first?.polishDictionaryResult?.headword, "kurtka")
            XCTAssertEqual(entry.selectedSenseText, "молния на одежде")
            XCTAssertEqual(entry.userNote, "Не замок-здание.")
            XCTAssertEqual(entry.sourceTrackID, "chapter-1")
            XCTAssertEqual(entry.audioStart, 12)
            XCTAssertEqual(entry.audioEnd, 16)

            entry.userNote = "Фикстура открыта текущей схемой."
            try container.mainContext.save()
        }

        do {
            let reopened = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                                              configurations: ModelConfiguration(url: store))
            let entry = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<DictionaryEntry>()).first)
            XCTAssertEqual(entry.userNote, "Фикстура открыта текущей схемой.")
            XCTAssertEqual(entry.contextTranslationText, "На куртке сломалась молния.",
                           "The frozen legacy sentence translation must survive reopen")
        }
    }
}
