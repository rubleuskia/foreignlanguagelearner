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
        let initialPresentation = UUID()
        var round = LearningRoundState(selection: .ten, selectedIDs: [first, second],
                                       presentationID: initialPresentation)

        XCTAssertTrue(round.recordAnswer(entryID: first, presentationID: initialPresentation,
                                         right: false, nextPresentationID: UUID()))
        XCTAssertEqual(round.pendingIDs, [second, first])
        XCTAssertEqual(round.wrongAttemptCount, 1)

        XCTAssertTrue(round.recordAnswer(entryID: second,
                                         presentationID: round.currentPresentationID,
                                         right: true, nextPresentationID: UUID()))
        XCTAssertTrue(round.recordAnswer(entryID: first,
                                         presentationID: round.currentPresentationID,
                                         right: true, nextPresentationID: UUID()))
        XCTAssertTrue(round.isComplete)
        XCTAssertEqual(round.completedIDs, [second, first])
        XCTAssertTrue(round.hasValidPartition)
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

    func testTranslationConfigurationPrefersHighFidelityWhenAvailable() {
        let first = TranslationConfiguration.next(previous: nil, source: "pl", target: "ru")
        let second = TranslationConfiguration.next(previous: first, source: "pl", target: "ru")

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
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio",
                                mediaFilename: "media.m4a", transcriptFilename: "story.srt",
                                duration: 10, segments: [], sourceLanguageCode: "pl")
        let entry = DictionaryEntry(text: "dzień dobry", item: item, segmentIndex: 0,
                                    context: SelectionContext(text: "Powiedział: dzień dobry.",
                                                              selection: NSRange(location: 12, length: 11)))
        entry.sourceTrackID = "chapter-2"
        entry.audioStart = 3
        entry.audioEnd = 4
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
        XCTAssertEqual(entry.sourceTrackID, "chapter-2")
        XCTAssertEqual(entry.audioStart, 3)
        XCTAssertEqual(entry.audioEnd, 4)
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
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
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

extension DictionaryFeatureTests {
    @MainActor func testManualBackupValidationAndRollback() throws {
        let (_, entry) = backupFixture()
        entry.manualAudioStart = 1.8
        entry.manualAudioEnd = 3.2
        let snapshot = DictionaryEntryRollbackSnapshot(entry)
        entry.manualAudioStart = nil
        entry.manualAudioEnd = nil
        snapshot.restore(entry)
        XCTAssertEqual(entry.manualAudioStart, 1.8)
        XCTAssertEqual(entry.manualAudioEnd, 3.2)
        entry.manualAudioEnd = nil
        XCTAssertThrowsError(try DictionaryTransferService.export(entries: [entry], includeContext: true, diagnosticEvents: []))
        entry.manualAudioEnd = 1
        XCTAssertThrowsError(try DictionaryTransferService.export(entries: [entry], includeContext: true, diagnosticEvents: []))
        entry.manualAudioStart = nil
        entry.manualAudioEnd = nil
        let old = try DictionaryTransferService.decode(DictionaryTransferService.export(entries: [entry], includeContext: true, diagnosticEvents: []).data)
        XCTAssertNil(old.entries.first?.details?.manualAudioStart)
        XCTAssertNil(old.entries.first?.details?.manualAudioEnd)
    }

    @MainActor private func backupFixture() -> (LearningItem, DictionaryEntry) {
        let item = LearningItem(id: UUID(), title: "Backup story", mediaKind: "audio",
                                mediaFilename: "", transcriptFilename: "story.txt", duration: 10, segments: [],
                                tracks: [.init(id: "chapter-1", title: "Chapter 1", mediaFilename: "audio/1.mp3", duration: 10)])
        let entry = DictionaryEntry(text: "zamek", item: item, segmentIndex: 2,
                                    context: .init(text: "To jest zamek.", selection: NSRange(location: 8, length: 5)),
                                    audioStart: 2, audioEnd: 3, sourceTrackID: "chapter-1")
        entry.translationText = "замок"
        entry.translationOrigin = .openAI
        entry.translationStatus = .ready
        entry.createdAt = Date(timeIntervalSince1970: 100.125)
        entry.translationUpdatedAt = Date(timeIntervalSince1970: 101.25)
        entry.learningLevel = 3
        entry.contextSelectedTranslationText = "старый замок"
        entry.contextTranslationText = "zamek — zamek — замок, крепость"
        entry.contextAnalysisUpdatedAt = Date(timeIntervalSince1970: 102.5)
        entry.wordHelpUpdatedAt = Date(timeIntervalSince1970: 103.75)
        entry.wordHelpItems = [.init(sourceText: "zamek", translationText: "замок", isGrammarWord: false,
            polishDictionaryResult: .init(requestedWord: "zamek", headword: "zamek", partOfSpeech: "rzeczownik",
                meanings: [.init(id: "1", definition: "budowla", examples: ["Stary zamek."], usageLabels: [])],
                sourceURL: "https://pl.wiktionary.org/wiki/zamek", revisionID: 12,
                fetchedAt: Date(timeIntervalSince1970: 104.125), formOfLemma: "zamek"))]
        entry.selectedSenseText = "крепость"
        entry.userNote = "Здесь речь о здании."
        return (item, entry)
    }

    @MainActor func testCompleteBackupRestoresAfterPersistentReopenAndKeepsAudioIdentity() throws {
        let (item, original) = backupFixture()
        original.phraseAudioStart = 1
        original.phraseAudioEnd = 5
        original.manualPhraseAudioStart = 0.5
        original.manualPhraseAudioEnd = 5.5
        original.manualAudioStart = 1.85
        original.manualAudioEnd = 3.2
        original.levelChangedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let file = try DictionaryTransferService.export(entries: [original], includeContext: true, diagnosticEvents: [])
        let document = try DictionaryTransferService.decode(file.data)
        XCTAssertEqual(document.schemaVersion, 3)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "dictionary.store"))
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let preview = DictionaryTransferService.preview(document: document, mode: .restore, existing: [])
            XCTAssertEqual(preview.additions, 1)
            XCTAssertTrue(try DictionaryTransferService.apply(preview, context: container.mainContext).isEmpty)
        }
        let reopened = try ModelContainer(for: schema, configurations: [configuration])
        let context = reopened.mainContext
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<DictionaryEntry>()).first)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.text, original.text)
        XCTAssertEqual(restored.translationText, original.translationText)
        XCTAssertEqual(restored.translationOrigin, .openAI)
        XCTAssertEqual(restored.translationStatus, .ready)
        XCTAssertEqual(restored.createdAt, original.createdAt)
        XCTAssertEqual(restored.translationUpdatedAt, original.translationUpdatedAt)
        XCTAssertEqual(restored.learningLevel, 3)
        XCTAssertEqual(restored.levelChangedAt, original.levelChangedAt)
        XCTAssertEqual(restored.contextText, original.contextText)
        XCTAssertEqual(restored.contextSelectionLocation, original.contextSelectionLocation)
        XCTAssertEqual(restored.contextSelectionLength, original.contextSelectionLength)
        XCTAssertEqual(restored.contextSelectedTranslationText, original.contextSelectedTranslationText)
        XCTAssertEqual(restored.contextTranslationText, original.contextTranslationText)
        XCTAssertEqual(restored.contextAnalysisUpdatedAt, original.contextAnalysisUpdatedAt)
        XCTAssertEqual(restored.wordHelpItems, original.wordHelpItems)
        XCTAssertEqual(restored.wordHelpUpdatedAt, original.wordHelpUpdatedAt)
        XCTAssertEqual(restored.selectedSenseText, original.selectedSenseText)
        XCTAssertEqual(restored.userNote, original.userNote)
        XCTAssertEqual(restored.sourceItemID, original.sourceItemID)
        XCTAssertEqual(restored.localSourceItemID, original.localSourceItemID)
        XCTAssertEqual(restored.sourceTrackID, "chapter-1")
        XCTAssertEqual(restored.segmentIndex, 2)
        XCTAssertEqual(restored.audioStart, 2)
        XCTAssertEqual(restored.audioEnd, 3)
        XCTAssertEqual(restored.manualAudioStart, 1.85)
        XCTAssertEqual(restored.manualAudioEnd, 3.2)
        XCTAssertEqual(restored.phraseAudioStart, 1)
        XCTAssertEqual(restored.phraseAudioEnd, 5)
        XCTAssertEqual(restored.manualPhraseAudioStart, 0.5)
        XCTAssertEqual(restored.manualPhraseAudioEnd, 5.5)
        XCTAssertNil(PhraseAudioSourceResolver.resolve(entry: restored, items: [], fileExists: { _ in true }))
        context.insert(item)
        try context.save()
        let source = PhraseAudioSourceResolver.resolve(entry: restored, items: [item], fileExists: { _ in true })
        XCTAssertEqual(source?.identity.range, 1.85...3.2)
        XCTAssertEqual(source?.identity.trackID, "chapter-1")
        let repeated = DictionaryTransferService.preview(document: document, mode: .restore, existing: [restored])
        _ = try DictionaryTransferService.apply(repeated, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DictionaryEntry>()), 1)
        let reexported = try DictionaryTransferService.decode(
            DictionaryTransferService.export(entries: [restored], includeContext: true, diagnosticEvents: []).data)
        XCTAssertEqual(reexported.entries.first?.details?.wordHelpItems, original.wordHelpItems)
    }

    @MainActor func testRestoreReplacesDetailsEvenWhenTranslationIsUnchangedButMergePreservesLocalData() throws {
        let (_, entry) = backupFixture()
        let document = try DictionaryTransferService.decode(
            DictionaryTransferService.export(entries: [entry], includeContext: true, diagnosticEvents: []).data)
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.insert(entry)
        entry.learningLevel = 1
        entry.userNote = "Changed locally"
        entry.contextTranslationText = nil
        try context.save()
        let merge = DictionaryTransferService.preview(document: document, mode: .merge, existing: [entry])
        XCTAssertEqual(merge.unchanged, 1)
        _ = try DictionaryTransferService.apply(merge, context: context)
        XCTAssertEqual(entry.userNote, "Changed locally")
        XCTAssertEqual(entry.learningLevel, 1)
        let restore = DictionaryTransferService.preview(document: document, mode: .restore, existing: [entry])
        XCTAssertEqual(restore.restorations, 1)
        _ = try DictionaryTransferService.apply(restore, context: context)
        XCTAssertEqual(entry.userNote, "Здесь речь о здании.")
        XCTAssertEqual(entry.learningLevel, 3)
        XCTAssertNotNil(entry.contextTranslationText)
        entry.text = "different identity"
        try context.save()
        let conflict = DictionaryTransferService.preview(document: document, mode: .restore, existing: [entry])
        XCTAssertEqual(conflict.conflicts, 1)
        _ = try DictionaryTransferService.apply(conflict, context: context)
        XCTAssertEqual(entry.text, "different identity")
    }

    @MainActor func testLegacyBackupStillRestoresAndPreservesTranslationOrigin() throws {
        let (_, original) = backupFixture()
        original.phraseAudioStart = 1
        original.phraseAudioEnd = 5
        original.manualPhraseAudioStart = 0.5
        original.manualPhraseAudioEnd = 5.5
        original.manualAudioStart = 1.85
        original.manualAudioEnd = 3.2
        original.levelChangedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let file = try DictionaryTransferService.export(entries: [original], includeContext: true, diagnosticEvents: [])
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: file.data) as? [String: Any])
        root["schemaVersion"] = 1
        root.removeValue(forKey: "readingVocabulary")
        root["exportedAt"] = "2026-10-17T19:03:54Z"
        var entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "details")
        entries[0]["createdAt"] = "2026-10-17T16:29:03Z"
        root["entries"] = entries
        let document = try DictionaryTransferService.decode(JSONSerialization.data(withJSONObject: root))
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let preview = DictionaryTransferService.preview(document: document, mode: .merge, existing: [])
        _ = try DictionaryTransferService.apply(preview, context: container.mainContext)
        let restored = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<DictionaryEntry>()).first)
        XCTAssertEqual(restored.translationOrigin, .openAI)
        XCTAssertEqual(restored.learningLevel, 3)
        XCTAssertEqual(restored.levelChangedAt, original.levelChangedAt)
        XCTAssertEqual(restored.contextText, original.contextText)
        XCTAssertNil(restored.contextTranslationText)
        XCTAssertNil(restored.audioStart)
    }

    @MainActor func testBackupRejectsIncompleteAndInvalidAudioMetadata() throws {
        let (_, entry) = backupFixture()
        let file = try DictionaryTransferService.export(entries: [entry], includeContext: true, diagnosticEvents: [])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: file.data) as? [String: Any])
        for mutation in ["missing-details", "partial-audio", "reversed-audio", "negative-index", "overflow-context"] {
            var changed = root
            var entries = try XCTUnwrap(changed["entries"] as? [[String: Any]])
            var details = try XCTUnwrap(entries[0]["details"] as? [String: Any])
            switch mutation {
            case "missing-details": entries[0].removeValue(forKey: "details")
            case "partial-audio": details.removeValue(forKey: "audioEnd"); entries[0]["details"] = details
            case "reversed-audio": details["audioEnd"] = 1; entries[0]["details"] = details
            case "negative-index": details["segmentIndex"] = -1; entries[0]["details"] = details
            default:
                var source = try XCTUnwrap(entries[0]["source"] as? [String: Any])
                var selectionContext = try XCTUnwrap(source["context"] as? [String: Any])
                selectionContext["selectionUTF16"] = ["location": 1, "length": Int.max]
                source["context"] = selectionContext; entries[0]["source"] = source
            }
            changed["entries"] = entries
            XCTAssertThrowsError(try DictionaryTransferService.decode(JSONSerialization.data(withJSONObject: changed)), mutation)
        }
        entry.audioEnd = 1
        XCTAssertThrowsError(try DictionaryTransferService.export(entries: [entry], includeContext: true, diagnosticEvents: []))
    }

    @MainActor func testRestoreRequeuesInterruptedTranslationAndPreservesUntranslatedNotes() throws {
        let (_, entry) = backupFixture()
        entry.translationText = nil
        entry.translationStatus = .translating
        let document = try DictionaryTransferService.decode(
            DictionaryTransferService.export(entries: [entry], includeContext: true, diagnosticEvents: []).data)
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let preview = DictionaryTransferService.preview(document: document, mode: .restore, existing: [])
        let pending = try DictionaryTransferService.apply(preview, context: container.mainContext)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.translationStatus, .pending)
        XCTAssertEqual(pending.first?.userNote, entry.userNote)
        XCTAssertNil(pending.first?.translationOrigin)
    }
}
