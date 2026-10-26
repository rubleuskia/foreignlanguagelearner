import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import UIKit
import XCTest
import ZIPFoundation
@testable import ForeignLanguageLearner

final class ProgressiveBookTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func audio(in directory: URL) throws -> URL {
        let url = directory.appending(path: "chapter.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @MainActor private func database() throws -> ModelContainer {
        try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor private func book(_ context: ModelContext) throws -> LearningItem {
        let item = LearningItem(id: UUID(), title: "Book", mediaKind: "text", mediaFilename: "",
            transcriptFilename: "original.txt", duration: 0, segments: [.init(start: nil, end: nil, text: "Old text")])
        context.insert(item)
        let directory = MediaImportService.directory(for: item.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Old text".utf8).write(to: directory.appending(path: "original.txt"))
        try context.save()
        return item
    }

    private func prepared(in directory: URL, text: String = "New text", tracks: [LearningTrack] = []) throws -> BookImportService.Prepared {
        try Data(text.utf8).write(to: directory.appending(path: "text.txt"))
        return .init(transactionID: UUID(), itemID: UUID(), title: "Book", sourceLanguage: "en",
            tracks: tracks, transcriptFilename: "text.txt", duration: tracks.reduce(0) { $0 + $1.duration }, stagedBookDirectory: directory)
    }

    func testIndependentTextAndAudioImportsAndAudioOnlyZIP() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appending(path: "book.txt")
        try Data("A small story.".utf8).write(to: text)
        let audio = try audio(in: directory)
        let service = BookImportService()
        for (audioURL, textURL) in [(nil as URL?, text as URL?), (audio as URL?, nil as URL?), (audio as URL?, text as URL?)] {
            let preview = try await service.previewFiles(audio: audioURL, text: textURL)
            let prepared = try await service.prepare(preview, title: "Story", orderedTracks: preview.tracks,
                transcriptPath: preview.selectedTranscript, externalTranscript: nil)
            XCTAssertEqual(prepared.tracks.isEmpty, audioURL == nil)
            XCTAssertEqual(prepared.transcriptFilename.isEmpty, textURL == nil)
            let words = try await service.vocabularyPreview(prepared)
            XCTAssertEqual(words.words.isEmpty, textURL == nil)
            XCTAssertEqual(prepared.tracks.count, audioURL == nil ? 0 : 1)
            await service.cancel(preview)
        }
        let archiveURL = directory.appending(path: "audio.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "chapter.wav", fileURL: audio)
        let preview = try await service.previewArchive(archiveURL)
        let prepared = try await service.prepare(preview, title: "Audio book", orderedTracks: preview.tracks,
            transcriptPath: nil, externalTranscript: nil)
        XCTAssertEqual(prepared.tracks.count, 1)
        XCTAssertEqual(prepared.transcriptFilename, "")
        await service.cancel(preview)
    }

    func testEmptyTextRejectedBeforePublishingFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appending(path: "empty.txt")
        try Data(" \n ".utf8).write(to: text)
        do { _ = try await BookImportService().previewFiles(audio: nil, text: text); XCTFail("Empty text accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("empty")) }
    }

    @MainActor func testTextOnlyDescriptorAndCapabilities() throws {
        let db = try database(), item = try book(db.mainContext)
        defer { try? FileManager.default.removeItem(at: MediaImportService.directory(for: item.id)) }
        XCTAssertFalse(item.hasAudio)
        XCTAssertTrue(item.hasText)
        XCTAssertEqual(item.resourceStatus, "Text only")
        XCTAssertTrue(BookMediaDescriptor(item: item).tracks.isEmpty)
        XCTAssertEqual(item.readingProgress, 0)
    }

    @MainActor func testTextReplacementKeepsDictionaryAndStudiedWordsButClearsOldAudio() throws {
        let db = try database(), context = db.mainContext, item = try book(context)
        defer { try? FileManager.default.removeItem(at: MediaImportService.directory(for: item.id)) }
        item.isBookCompleted = true; item.readingCharacterOffset = 5
        let entry = DictionaryEntry(text: "Old", item: item, segmentIndex: 0, audioStart: 1, audioEnd: 2)
        entry.translationText = "Старый"; entry.learningLevel = 3
        entry.manualAudioStart = 1.2; entry.manualAudioEnd = 1.8
        context.insert(entry)
        context.insert(ReadVocabularyWord(languageCode: "pl", normalizedForm: "old", firstLearnedAt: Date()))
        try context.save()
        let stage = try temporaryDirectory()
        let value = try prepared(in: stage)
        try BookResourceUpdateService.apply(value, to: item, action: .text, expectedRevision: "", context: context)
        XCTAssertEqual(item.segments.first?.text, "New text")
        XCTAssertEqual(item.readingCharacterOffset, 0)
        XCTAssertFalse(item.isBookCompleted)
        XCTAssertTrue(item.isSourceLanguageLocked, "Replacing text must not unlock the language used by historical reading knowledge")
        XCTAssertEqual(entry.translationText, "Старый")
        XCTAssertEqual(entry.learningLevel, 3)
        XCTAssertNil(entry.audioStart); XCTAssertNil(entry.manualAudioStart)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReadVocabularyWord>()), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MediaImportService.directory(for: item.id).appending(path: "original.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: MediaImportService.directory(for: item.id).appending(path: item.transcriptFilename).path))
    }

    @MainActor func testFailedSaveRestoresBookAndDictionaryAndAllowsRetry() throws {
        let db = try database(), context = db.mainContext, item = try book(context)
        defer { try? FileManager.default.removeItem(at: MediaImportService.directory(for: item.id)) }
        let entry = DictionaryEntry(text: "Old", item: item, segmentIndex: 0, audioStart: 1, audioEnd: 2)
        context.insert(entry); try context.save()
        let stage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let value = try prepared(in: stage)
        XCTAssertThrowsError(try BookResourceUpdateService.apply(value, to: item, action: .text, expectedRevision: "", context: context,
            save: { throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertEqual(item.transcriptFilename, "original.txt")
        XCTAssertEqual(item.segments.first?.text, "Old text")
        XCTAssertEqual(item.resourceRevision, "")
        XCTAssertEqual(entry.audioStart, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.appending(path: "text.txt").path))
        try BookResourceUpdateService.apply(value, to: item, action: .text, expectedRevision: "", context: context)
        XCTAssertEqual(item.segments.first?.text, "New text")
    }

    @MainActor func testStalePreviewCannotOverwriteNewResources() throws {
        let db = try database(), context = db.mainContext, item = try book(context)
        defer { try? FileManager.default.removeItem(at: MediaImportService.directory(for: item.id)) }
        item.resourceRevision = "newer"; try context.save()
        let stage = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }
        XCTAssertThrowsError(try BookResourceUpdateService.apply(try prepared(in: stage), to: item,
            action: .text, expectedRevision: "", context: context))
        XCTAssertEqual(item.transcriptFilename, "original.txt")
    }

    @MainActor func testAudioReplacementPreservesTextAndCannotReuseOldPhraseSource() throws {
        let db = try database(), context = db.mainContext, item = try book(context)
        defer { try? FileManager.default.removeItem(at: MediaImportService.directory(for: item.id)) }
        item.mediaFilename = "old.wav"; item.duration = 1
        let entry = DictionaryEntry(text: "Old", item: item, segmentIndex: 0, audioStart: 0, audioEnd: 0.5)
        context.insert(entry); try context.save()
        let stage = try temporaryDirectory()
        _ = try audio(in: stage)
        let track = LearningTrack(id: "old", title: "Chapter", mediaFilename: "chapter.wav", duration: 1)
        try BookResourceUpdateService.apply(try prepared(in: stage, tracks: [track]), to: item,
            action: .audio, expectedRevision: "", context: context)
        XCTAssertTrue(item.hasText); XCTAssertTrue(item.hasAudio)
        XCTAssertNotEqual(item.tracks.first?.id, "old")
        XCTAssertEqual(try ReadingCompletionService.sources(item: item, scope: .book).first?.load(), "Old text")
        XCTAssertNil(PhraseAudioSourceResolver.resolve(entry: entry, items: [item]))
        XCTAssertEqual(item.lastPosition, 0)
    }

    @MainActor func testRecoveryKeepsPublishedGenerationAndRemovesUnpublishedGeneration() throws {
        let db = try database(), context = db.mainContext, item = try book(context)
        defer { try? FileManager.default.removeItem(at: MediaImportService.directory(for: item.id)) }
        try FileManager.default.createDirectory(at: BookResourceJournal.root, withIntermediateDirectories: true)
        for published in [false, true] {
            let journal = BookResourceJournal(id: UUID(), itemID: item.id)
            try FileManager.default.createDirectory(at: journal.directory, withIntermediateDirectories: true)
            try Data("Recovered".utf8).write(to: journal.directory.appending(path: "text.txt"))
            try JSONEncoder().encode(journal).write(to: journal.url)
            if published { item.transcriptFilename = "\(journal.prefix)/text.txt"; item.resourceRevision = journal.id.uuidString; try context.save() }
            try BookResourceUpdateService.recover(context: context)
            XCTAssertEqual(FileManager.default.fileExists(atPath: journal.directory.path), published)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path))
        }
    }

    func testSynchronizationRejectsChangedAudioAndText() async throws {
        let incoming = try temporaryDirectory(), current = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: incoming); try? FileManager.default.removeItem(at: current) }
        let track = LearningTrack(id: "incoming", title: "Chapter", mediaFilename: "chapter.wav", subtitleFilename: "text.vtt", duration: 1, alignmentStatus: .aligned)
        let value = try prepared(in: incoming, tracks: [track])
        try Data([1]).write(to: incoming.appending(path: "chapter.wav"))
        try Data([2]).write(to: current.appending(path: "chapter.wav"))
        let validator = BookSynchronizationValidator()
        do { try await validator.validate(value, existing: [track], directory: current, transcriptFilename: ""); XCTFail("Changed audio accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Audio differs")) }
        try Data([1]).write(to: current.appending(path: "chapter.wav"))
        try Data("Different text".utf8).write(to: current.appending(path: "text.txt"))
        do { try await validator.validate(value, existing: [track], directory: current, transcriptFilename: "text.txt"); XCTFail("Changed text accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("text differs")) }
        try Data("New text".utf8).write(to: current.appending(path: "text.txt"))
        try await validator.validate(value, existing: [track], directory: current, transcriptFilename: "text.txt")
    }

    func testResetTipsPreservesEnabledPreferenceAndUnrelatedData() {
        let suite = "onboarding-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: OnboardingPreferences.enabledKey)
        defaults.set("unchanged", forKey: "unrelated")
        defaults.set(true, forKey: OnboardingPreferences.skippedKey)
        for step in OnboardingStep.allCases { defaults.set(true, forKey: step.key) }
        OnboardingPreferences.reset(defaults)
        XCTAssertFalse(defaults.bool(forKey: OnboardingPreferences.enabledKey))
        XCTAssertFalse(defaults.bool(forKey: OnboardingPreferences.skippedKey))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "unchanged")
        for step in OnboardingStep.allCases { XCTAssertFalse(defaults.bool(forKey: step.key)) }
    }

    @MainActor func testAttachSynchronizationKeepsSourceIdentityAndManualAudio() async throws {
        let db = try database(), context = db.mainContext, item = try book(context)
        let directory = MediaImportService.directory(for: item.id)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = try audio(in: directory)
        item.mediaKind = "audio"; item.duration = 1
        item.tracks = [.init(id: "stable", title: "Chapter", mediaFilename: "chapter.wav", duration: 1, lastPosition: 0.4)]
        item.segments = []
        let entry = DictionaryEntry(text: "Old", item: item, segmentIndex: 0, audioStart: 0, audioEnd: 0.3, sourceTrackID: "stable")
        entry.manualAudioStart = 0.1; entry.manualAudioEnd = 0.25
        context.insert(entry); try context.save()
        let stage = try temporaryDirectory()
        let incoming = LearningTrack(id: "package-id", title: "Chapter", mediaFilename: "chapter.wav",
            subtitleFilename: "subtitle.vtt", duration: 1, alignmentStatus: .aligned, wordTimingsFilename: "words.json")
        let value = try prepared(in: stage, text: "Old text", tracks: [incoming])
        try FileManager.default.copyItem(at: audioURL, to: stage.appending(path: "chapter.wav"))
        try Data("WEBVTT\n\n00:00:00.000 --> 00:00:00.900\nOld text\n".utf8).write(to: stage.appending(path: "subtitle.vtt"))
        let timing = WordAudioTimingFile(schemaVersion: 1, trackID: "package-id",
            audioSHA256: try WordAudioTimingFile.audioHash(audioURL), textSHA256: BookTextNormalization.sha256("Old text"),
            words: [.init(text: "Old", start: 0, end: 0.3), .init(text: "text", start: 0.3, end: 0.9)])
        try JSONEncoder().encode(timing).write(to: stage.appending(path: "words.json"))
        try await BookSynchronizationValidator().validate(value, existing: item.tracks, directory: directory, transcriptFilename: item.transcriptFilename)
        try BookResourceUpdateService.apply(value, to: item, action: .synchronization, expectedRevision: "", context: context)
        let track = try XCTUnwrap(item.tracks.first)
        XCTAssertEqual(track.id, "stable")
        XCTAssertEqual(track.mediaFilename, "chapter.wav")
        XCTAssertEqual(track.lastPosition, 0.4)
        XCTAssertEqual(entry.manualAudioStart, 0.1)
        XCTAssertEqual(entry.manualAudioEnd, 0.25)
        XCTAssertNil(entry.segmentIndex)
        let document = try TrackTranscriptLoader.load(track: track, directory: directory)
        XCTAssertEqual(document.wordTimings.count, 2)
        XCTAssertEqual(PhraseAudioSourceResolver.resolve(entry: entry, items: [item])?.identity.range, 0.1...0.25)
        XCTAssertEqual(try WordAudioTimingFile.read(directory.appending(path: try XCTUnwrap(track.wordTimingsFilename))).trackID, "stable")
    }

    @MainActor func testPartialBookAndReadingAnchorPersistAcrossReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.store")
        let id = UUID()
        do {
            let db = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                configurations: ModelConfiguration(url: url))
            let item = LearningItem(id: id, title: "Text", mediaKind: "text", mediaFilename: "", transcriptFilename: "text.txt", duration: 0,
                segments: [.init(start: nil, end: nil, text: "A story")])
            item.resourceRevision = "revision"; item.readingCharacterOffset = 4
            db.mainContext.insert(item); try db.mainContext.save()
        }
        let reopened = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
            configurations: ModelConfiguration(url: url))
        let item = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<LearningItem>()).first)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.readingCharacterOffset, 4)
        XCTAssertEqual(item.resourceRevision, "revision")
        XCTAssertFalse(item.hasAudio); XCTAssertTrue(item.hasText)
    }

    @MainActor func testDemoIsIdempotentAndDoesNotCreateLearningData() async throws {
        let db = try database()
        let demoID = UUID()
        let temporary = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: MediaImportService.directory(for: demoID))
        }
        let source = try audio(in: temporary)
        let item = try await DemoBookService.add(context: db.mainContext, itemID: demoID, narration: { destination in
            try FileManager.default.copyItem(at: source, to: destination)
        })
        XCTAssertTrue(item.hasAudio); XCTAssertTrue(item.hasText)
        XCTAssertEqual(item.resourceStatus, "Synchronized")
        let track = try XCTUnwrap(item.tracks.first)
        XCTAssertEqual(try TrackTranscriptLoader.load(track: track, directory: MediaImportService.directory(for: item.id)).text, DemoBookService.text)
        let repeated = try await DemoBookService.add(context: db.mainContext, itemID: demoID, narration: { _ in XCTFail("Narration must not run twice") })
        XCTAssertEqual(repeated.id, item.id)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<LearningItem>()), 1)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<DictionaryEntry>()), 0)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<ReadVocabularyWord>()), 0)
    }

    @MainActor func testDemoWorksAsTextWhenDeviceVoiceIsUnavailable() async throws {
        let db = try database()
        let demoID = UUID()
        defer { try? FileManager.default.removeItem(at: MediaImportService.directory(for: demoID)) }
        let item = try await DemoBookService.add(context: db.mainContext, itemID: demoID, narration: { _ in throw CocoaError(.featureUnsupported) })
        XCTAssertTrue(item.hasText); XCTAssertFalse(item.hasAudio)
        XCTAssertEqual(item.segments.first?.text, DemoBookService.text)
        XCTAssertTrue(item.title.contains("Text example"))
    }

    @MainActor func testUntimedReadingRestoresCharacterAnchorOnceWithoutSelectingText() {
        let text = String(repeating: "A small story with a new word.\n\n", count: 150)
        let document = TranscriptDocument(segments: [.init(start: nil, end: nil, text: text)])
        let parent = TranscriptTextView(document: document, activeSegment: nil, following: .constant(false),
            followGeneration: 0, onSelectionBegan: {}, initialReadingOffset: 1_200,
            handleSelection: { _, _, _, _, _ in })
        let coordinator = parent.makeCoordinator()
        let view = TranscriptTextView.makeTextView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        coordinator.apply(to: view)
        view.layoutIfNeeded()
        coordinator.restoreReadingPosition(in: view)
        XCTAssertGreaterThan(view.contentOffset.y, 0)
        XCTAssertEqual(view.selectedRange.length, 0)
        view.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
        coordinator.apply(to: view)
        coordinator.restoreReadingPosition(in: view)
        XCTAssertEqual(view.contentOffset.y, 100, accuracy: 1)
        XCTAssertEqual(view.text, document.text)
    }
}
