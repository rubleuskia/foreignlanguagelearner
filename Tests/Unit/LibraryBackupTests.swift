import Foundation
import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class LibraryBackupTests: XCTestCase {
    @MainActor private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self])
        let configuration = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor private func book(_ title: String = "Original title", text: String = "To jest tekst książki.") throws -> LearningItem {
        let item = LearningItem(id: UUID(), title: title, mediaKind: "audio", mediaFilename: "",
            transcriptFilename: "book.txt", duration: 100, segments: [], tracks: [
                .init(id: "one", title: "One", mediaFilename: "one.m4a", subtitleFilename: "one.srt", duration: 40,
                      wordTimingsFilename: "one.words.json"),
                .init(id: "two", title: "Two", mediaFilename: "two.m4a", subtitleFilename: "two.srt", duration: 60)
            ])
        let root = MediaImportService.directory(for: item.id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appending(path: "book.txt"), atomically: true, encoding: .utf8)
        return item
    }

    @MainActor private func cleanup(_ items: LearningItem...) {
        for item in items { try? FileManager.default.removeItem(at: MediaImportService.directory(for: item.id)) }
    }

    @MainActor private func entry(_ item: LearningItem, text: String = "zamek") -> DictionaryEntry {
        let value = DictionaryEntry(text: text, item: item, segmentIndex: 0,
            context: .init(text: "Stary \(text) stoi na wzgórzu.", selection: NSRange(location: 6, length: text.utf16.count)),
            audioStart: 2, audioEnd: 4, sourceTrackID: "two")
        value.translationText = "замок"; value.translationStatus = .ready
        value.learningLevel = 3; value.levelChangedAt = Date(timeIntervalSince1970: 1234)
        value.userNote = "Personal note"; value.selectedSenseText = "крепость"
        value.contextTranslationText = "zamek — zamek — замок"
        value.contextSelectedTranslationText = "старый замок"
        value.manualAudioStart = 1.5; value.manualAudioEnd = 4.5
        value.phraseAudioStart = 1; value.phraseAudioEnd = 8
        return value
    }

    @MainActor func testNewPhoneRoundTripPersistsProgressSettingsKnowledgeAndRelinksPhraseAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceSuite = "BackupSource.\(UUID())", targetSuite = "BackupTarget.\(UUID())"
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        let targetDefaults = try XCTUnwrap(UserDefaults(suiteName: targetSuite))
        defer { sourceDefaults.removePersistentDomain(forName: sourceSuite); targetDefaults.removePersistentDomain(forName: targetSuite) }
        let source = try container()
        let original = try book(text: "Private source text never embedded in backup.")
        let replacement = try book("Different title", text: "Private source text never embedded in backup.")
        let sourceDirectory = MediaImportService.directory(for: original.id)
        let replacementDirectory = MediaImportService.directory(for: replacement.id)
        let replacementID = replacement.id
        defer {
            try? FileManager.default.removeItem(at: sourceDirectory)
            try? FileManager.default.removeItem(at: replacementDirectory)
            withExtendedLifetime(source) { }
        }
        original.createdAt = Date(timeIntervalSince1970: 100)
        original.sourceLanguageCode = "pl"
        original.isBookCompleted = true; original.readingVocabularyMigrationVersion = 1
        original.lastTrackID = "two"; original.lastPosition = 52
        original.tracks[0].isCompleted = true; original.tracks[0].lastPosition = 40
        original.tracks[1].lastPosition = 12
        let first = entry(original)
        let second = entry(original, text: "dom")
        source.mainContext.insert(original); source.mainContext.insert(first); source.mainContext.insert(second)
        source.mainContext.insert(ReadVocabularyWord(languageCode: "pl", normalizedForm: "zamek", firstLearnedAt: .distantPast))
        ReadingKnowledge.insert(try ReadingKnowledge.encode(["dom"]), language: "pl", context: source.mainContext)
        try ContextAnalysisSettings.setPrompt("Custom translation instructions", in: sourceDefaults)
        try ContextAnalysisSettings.setWordExplanationPrompt("Custom examples", in: sourceDefaults)
        ContextAnalysisSettings.setSelectedModel(.nano, in: sourceDefaults)
        ContextAnalysisSettings.setCloudAnalysisEnabled(true, in: sourceDefaults)
        sourceDefaults.set(12.5, forKey: "learning.cooldown.level.1")
        var round = LearningRoundState(selection: .five, selectedIDs: [first.id, second.id])
        _ = round.recordAnswer(entryID: first.id, presentationID: round.currentPresentationID, right: false)
        LearningRoundCheckpoint.save(round, defaults: sourceDefaults)
        let sourceCache = directory.appending(path: "source-cache.json")
        let targetCache = directory.appending(path: "target-cache.json")
        let explanation = WordExplanation(definition: "Определение.", meaningInContext: "Здесь это крепость.",
            examples: [.init(phrase: "Nowy zamek przyciąga wielu turystów każdego lata.", translation: "Новый замок привлекает много туристов каждое лето.")])
        try WordExplanationCache.restoreRecords([.init(key: String(repeating: "a", count: 64), value: explanation)], at: sourceCache)
        let file = try LibraryBackupService.export(context: source.mainContext, defaults: sourceDefaults, cacheURL: sourceCache)
        XCTAssertFalse(String(decoding: file.data, as: UTF8.self).contains("Private source text"))
        let document = try LibraryBackupService.decode(file.data)
        XCTAssertEqual(document.books.count, 1)
        XCTAssertEqual(document.wordExplanations.first?.value, explanation)
        let store = directory.appending(path: "target.store")
        let target = try container(url: store)
        defer { withExtendedLifetime(target) { } }
        target.mainContext.insert(replacement)
        let unrelated = entry(replacement, text: "inne")
        target.mainContext.insert(unrelated)
        try target.mainContext.save()
        let preview = try LibraryBackupService.preview(document, context: target.mainContext)
        XCTAssertTrue(preview.canRestore)
        XCTAssertEqual(preview.matches[original.id], replacement.id)
        _ = try LibraryBackupService.restore(preview, context: target.mainContext, defaults: targetDefaults, cacheURL: targetCache)
        // Repeat import must remain idempotent with old source UUIDs in the portable file.
        _ = try LibraryBackupService.restore(preview, context: target.mainContext, defaults: targetDefaults, cacheURL: targetCache)
        let reopened = try container(url: store)
        let restoredBook = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<LearningItem>()).first)
        XCTAssertEqual(restoredBook.id, replacementID)
        XCTAssertEqual(restoredBook.title, original.title)
        XCTAssertEqual(restoredBook.createdAt, original.createdAt)
        XCTAssertTrue(restoredBook.isBookCompleted)
        XCTAssertEqual(restoredBook.readingVocabularyMigrationVersion, 1)
        XCTAssertEqual(restoredBook.lastPosition, 52)
        XCTAssertEqual(restoredBook.lastTrackID, "two")
        XCTAssertTrue(restoredBook.tracks[0].isCompleted)
        XCTAssertEqual(restoredBook.tracks[1].lastPosition, 12)
        XCTAssertEqual(restoredBook.tracks[0].wordTimingsFilename, "one.words.json")
        let entries = try reopened.mainContext.fetch(FetchDescriptor<DictionaryEntry>())
        XCTAssertEqual(entries.count, 3)
        let restoredEntry = try XCTUnwrap(entries.first { $0.id == first.id })
        XCTAssertEqual(restoredEntry.localSourceItemID, replacementID)
        XCTAssertEqual(restoredEntry.sourceItemID, replacementID)
        XCTAssertEqual(restoredEntry.sourceTrackID, "two")
        XCTAssertEqual(restoredEntry.manualAudioStart, 1.5)
        XCTAssertEqual(restoredEntry.phraseAudioEnd, 8)
        XCTAssertEqual(restoredEntry.learningLevel, 3)
        XCTAssertEqual(restoredEntry.levelChangedAt, first.levelChangedAt)
        XCTAssertEqual(restoredEntry.userNote, first.userNote)
        XCTAssertEqual(restoredEntry.contextTranslationText, first.contextTranslationText)
        let words = try ReadingKnowledge.words(context: reopened.mainContext)
        XCTAssertEqual(Set(words.map(\.normalizedForm)), ["zamek", "dom"])
        XCTAssertEqual(LearningRoundCheckpoint.load(defaults: targetDefaults), round)
        XCTAssertEqual(ContextAnalysisSettings.prompt(in: targetDefaults), "Custom translation instructions")
        XCTAssertEqual(ContextAnalysisSettings.wordExplanationPrompt(in: targetDefaults), "Custom examples")
        XCTAssertEqual(ContextAnalysisSettings.selectedModel(in: targetDefaults), .nano)
        XCTAssertTrue(ContextAnalysisSettings.isCloudAnalysisEnabled(in: targetDefaults))
        XCTAssertEqual(LearningCooldown.hours(level: 1, defaults: targetDefaults), 12.5)
        XCTAssertEqual(try WordExplanationCache.backupRecords(at: targetCache).first?.value, explanation)
    }

    @MainActor func testMissingDifferentEditionAndAmbiguousBooksBlockRestore() throws {
        let source = try container(), target = try container()
        let original = try book(), wrongEdition = try book(text: "Different text with same title.")
        let copy1 = try book(), copy2 = try book()
        defer { cleanup(original, wrongEdition, copy1, copy2) }
        source.mainContext.insert(original)
        let file = try LibraryBackupService.export(context: source.mainContext, cacheURL: nil)
        let document = try LibraryBackupService.decode(file.data)
        XCTAssertFalse(try LibraryBackupService.preview(document, context: target.mainContext).canRestore)
        target.mainContext.insert(wrongEdition)
        XCTAssertFalse(try LibraryBackupService.preview(document, context: target.mainContext).canRestore)
        target.mainContext.insert(copy1); target.mainContext.insert(copy2)
        let ambiguous = try LibraryBackupService.preview(document, context: target.mainContext)
        XCTAssertFalse(ambiguous.canRestore)
        XCTAssertThrowsError(try LibraryBackupService.restore(ambiguous, context: target.mainContext, cacheURL: nil))
        target.mainContext.delete(copy2)
        try target.mainContext.save()
        let preview = try LibraryBackupService.preview(document, context: target.mainContext)
        XCTAssertTrue(preview.canRestore)
        // A changed transcript between preview and Apply must not receive the saved progress.
        try "Changed again".write(to: MediaImportService.directory(for: copy1.id).appending(path: "book.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LibraryBackupService.restore(preview, context: target.mainContext, cacheURL: nil))
    }

    @MainActor func testFailedSaveRollsBackModelsCacheAndSettings() throws {
        enum Failure: Error { case disk }
        let source = try container(), target = try container()
        let original = try book(), replacement = try book("Local title")
        defer { cleanup(original, replacement) }
        original.isBookCompleted = true; original.lastPosition = 20
        original.tracks[0].isCompleted = true
        source.mainContext.insert(original)
        let incoming = entry(original)
        source.mainContext.insert(incoming)
        source.mainContext.insert(ReadVocabularyWord(languageCode: "pl", normalizedForm: "zamek"))
        let suite = "BackupFailure.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try ContextAnalysisSettings.setWordExplanationPrompt("Local instructions", in: defaults)
        let document = try LibraryBackupService.decode(LibraryBackupService.export(context: source.mainContext, cacheURL: nil).data)
        target.mainContext.insert(replacement)
        let local = entry(replacement)
        local.id = incoming.id; local.learningLevel = 1; local.userNote = "Local note"
        target.mainContext.insert(local)
        try target.mainContext.save()
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let previousCache = Data("[]".utf8)
        try previousCache.write(to: cacheURL)
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let preview = try LibraryBackupService.preview(document, context: target.mainContext)
        XCTAssertThrowsError(try LibraryBackupService.restore(preview, context: target.mainContext,
            defaults: defaults, cacheURL: cacheURL, save: { _ in throw Failure.disk }))
        XCTAssertEqual(local.learningLevel, 1)
        XCTAssertEqual(local.userNote, "Local note")
        XCTAssertEqual(local.localSourceItemID, replacement.id)
        XCTAssertEqual(replacement.title, "Local title")
        XCTAssertFalse(replacement.isBookCompleted)
        XCTAssertFalse(replacement.tracks[0].isCompleted)
        XCTAssertEqual(replacement.lastPosition, 0)
        XCTAssertTrue(try ReadingKnowledge.words(context: target.mainContext).isEmpty)
        XCTAssertEqual(ContextAnalysisSettings.wordExplanationPrompt(in: defaults), "Local instructions")
        XCTAssertEqual(try Data(contentsOf: cacheURL), previousCache)
        try target.mainContext.save()
    }

    @MainActor func testLegacyPartsAndEmptyLibraryRoundTrip() throws {
        let source = try container(), target = try container()
        let original = LearningItem(id: UUID(), title: "Legacy", mediaKind: "audio", mediaFilename: "media.m4a",
            transcriptFilename: "transcript.srt", duration: 100,
            segments: [.init(start: 0, end: 100, text: "Tekst")],
            parts: [.init(start: 0, end: 50, isCompleted: true, lastPosition: 50), .init(start: 50, end: 100, lastPosition: 75)])
        let replacement = LearningItem(id: UUID(), title: "Renamed", mediaKind: "audio", mediaFilename: "media.m4a",
            transcriptFilename: "transcript.srt", duration: 100, segments: original.segments)
        original.lastPosition = 75; source.mainContext.insert(original); target.mainContext.insert(replacement)
        let document = try LibraryBackupService.decode(LibraryBackupService.export(context: source.mainContext, cacheURL: nil).data)
        let preview = try LibraryBackupService.preview(document, context: target.mainContext)
        _ = try LibraryBackupService.restore(preview, context: target.mainContext, cacheURL: nil)
        XCTAssertEqual(replacement.parts, original.parts)
        XCTAssertEqual(replacement.readingProgress, 0.5)
        let empty = try container()
        let emptyDocument = try LibraryBackupService.decode(LibraryBackupService.export(context: empty.mainContext, cacheURL: nil).data)
        XCTAssertTrue(emptyDocument.books.isEmpty)
        XCTAssertTrue(try LibraryBackupService.preview(emptyDocument, context: empty.mainContext).canRestore)
    }

    @MainActor func testMalformedBackupsFailValidationBeforeMutation() throws {
        let source = try container()
        let item = try book(); defer { cleanup(item) }
        source.mainContext.insert(item)
        let data = try LibraryBackupService.export(context: source.mainContext, cacheURL: nil).data
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 999
        XCTAssertThrowsError(try LibraryBackupService.decode(JSONSerialization.data(withJSONObject: object)))
        object["schemaVersion"] = 1
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings["cooldowns"] = [-1, 2, 3]; object["settings"] = settings
        XCTAssertThrowsError(try LibraryBackupService.decode(JSONSerialization.data(withJSONObject: object)))
        settings["cooldowns"] = [1, 2, 3]; settings["wordPrompt"] = "  "; object["settings"] = settings
        XCTAssertThrowsError(try LibraryBackupService.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testRunningCacheActorSeesImportedExplanations() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WordExplanationCache(directory: directory)
        let key = String(repeating: "b", count: 64)
        let missing = await cache.value(for: key)
        XCTAssertNil(missing)
        let value = WordExplanation(definition: "Meaning", meaningInContext: "Here", examples: [.init(phrase: "Sentence", translation: "Перевод")])
        try WordExplanationCache.restoreRecords([.init(key: key, value: value)], at: directory.appending(path: "WordExplanations-v1.json"))
        let restored = await cache.value(for: key)
        XCTAssertEqual(restored, value)
    }
}
