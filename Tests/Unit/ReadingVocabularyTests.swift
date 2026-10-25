import AVFoundation
import ZIPFoundation
import Foundation
import SwiftData
import UIKit
import SwiftUI
import XCTest
@testable import ForeignLanguageLearner

final class ReadingVocabularyTests: XCTestCase {
    @MainActor func testPlaybackKeepsScreenAwakeAndReleasesOnPauseInterruptionAndClose() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "idle-timer-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = buffer.frameCapacity
        do {
            let audio = try AVAudioFile(forWriting: url, settings: format.settings)
            try audio.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = PlaybackController()
        defer { playback.close() }
        func waitForAwake(_ awake: Bool, line: UInt = #line) async throws {
            for _ in 0..<150 {
                if UIApplication.shared.isIdleTimerDisabled == awake { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, awake, line: line)
        }
        playback.open(url: url, position: 0)
        playback.play()
        try await waitForAwake(true)
        playback.pause()
        try await waitForAwake(false)
        playback.play()
        try await waitForAwake(true)
        // AVPlayer pauses itself during an audio-session interruption.
        playback.player.pause()
        try await waitForAwake(false)
        playback.play()
        try await waitForAwake(true)
        playback.seek(to: 1.95)
        for _ in 0..<150 {
            if !playback.wantsToPlay { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(playback.wantsToPlay)
        try await waitForAwake(false)
        playback.play()
        try await waitForAwake(true)
        playback.close()
        try await waitForAwake(false)
    }

    @MainActor private func container() throws -> ModelContainer {
        try ModelContainer(for: LearningItem.self, DictionaryEntry.self, ReadVocabularyWord.self, ReadVocabularyBatch.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @MainActor private func item(_ context: ModelContext, text: String = "Kot i kot. Kota śpi.") throws -> LearningItem {
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio", mediaFilename: "missing.m4a",
                                transcriptFilename: "story.txt", duration: 20,
                                segments: [.init(start: nil, end: nil, text: text)])
        item.readingVocabularyMigrationVersion = 1
        context.insert(item); try context.save()
        return item
    }

    func testTokenizerSurfaceFormsUnicodeAndExactUTF16Ranges() throws {
        let text = "👩🏽‍🚀 KÓT kót kot kota i a w łaska laska 123 abc123 biało-czerwony l’amour l'amour"
        let tokens = try VocabularyTokenizer.occurrences(in: text)
        XCTAssertEqual(tokens.first?.rangeUTF16, (text as NSString).range(of: "KÓT"))
        XCTAssertEqual(tokens[0].normalizedForm, tokens[1].normalizedForm)
        XCTAssertEqual(try VocabularyTokenizer.forms(in: "Kot kot KOT kota"), ["kot", "kota"])
        let forms = Set(tokens.map(\.normalizedForm))
        XCTAssertTrue(forms.isSuperset(of: ["i", "a", "w", "łaska", "laska", "abc", "biało", "czerwony", "l'amour"]))
        XCTAssertFalse(forms.contains("123"))
        XCTAssertEqual(tokens.filter { $0.normalizedForm == "l'amour" }.count, 2)
        XCTAssertEqual(try VocabularyTokenizer.language(" PL_pl "), "pl-pl")
        XCTAssertThrowsError(try VocabularyTokenizer.language("pl--PL"))
    }

    @MainActor func testBookCompletionDeduplicatesAndDoesNotCreateCards() async throws {
        let db = try container(), store = ReadingVocabularyStore()
        let story = try item(db.mainContext)
        await store.start(context: db.mainContext)
        let proposal = try await store.prepare(item: story, scope: .book)
        XCTAssertEqual(proposal.added, 4)
        XCTAssertFalse(story.isBookCompleted, "Preparation and cancelling confirmation have no effect")
        try await store.complete(proposal, context: db.mainContext)
        XCTAssertTrue(story.isBookCompleted)
        XCTAssertEqual(store.forms(for: "pl"), ["kot", "i", "kota", "śpi"])
        try await store.complete(proposal, context: db.mainContext)
        XCTAssertEqual(try ReadingKnowledge.words(context: db.mainContext).count, 4)
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<DictionaryEntry>()), 0)
        db.mainContext.delete(story); try db.mainContext.save(); try store.reload(context: db.mainContext)
        XCTAssertEqual(store.forms(for: "pl").count, 4)
    }

    @MainActor func testDictionaryLevelsAreIndependentAndLanguagesAreSeparate() async throws {
        let db = try container(), store = ReadingVocabularyStore()
        let story = try item(db.mainContext, text: "kot")
        let card = DictionaryEntry(text: "kot", item: story, segmentIndex: nil)
        card.learningLevel = 4; db.mainContext.insert(card); try db.mainContext.save()
        await store.start(context: db.mainContext)
        XCTAssertEqual(store.statistics(["kot"], language: "pl").new, 1)
        let proposal = try await store.prepare(item: story, scope: .book)
        try await store.complete(proposal, context: db.mainContext)
        XCTAssertEqual(store.statistics(["kot"], language: "pl").new, 0)
        XCTAssertEqual(store.statistics(["kot"], language: "en").new, 1)
        card.learningLevel = 1; try db.mainContext.save()
        XCTAssertEqual(store.statistics(["kot"], language: "pl").new, 0)
    }

    @MainActor func testUntimedTrackOnlyContributesWhenWholeBookReadAndSubtitlesAreIncluded() async throws {
        let db = try container(), store = ReadingVocabularyStore()
        let story = try item(db.mainContext)
        story.tracks = [LearningTrack(id: "one", title: "One", mediaFilename: "one.wav", duration: 10),
                        LearningTrack(id: "two", title: "Two", mediaFilename: "two.wav", subtitleFilename: "two.srt", duration: 10, alignmentStatus: .aligned)]
        let directory = MediaImportService.directory(for: story.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Kot pies".write(to: directory.appending(path: story.transcriptFilename), atomically: true, encoding: .utf8)
        try "1\n00:00:00,000 --> 00:00:01,000\nKot koń\n".write(to: directory.appending(path: "two.srt"), atomically: true, encoding: .utf8)
        try db.mainContext.save(); await store.start(context: db.mainContext)
        let track = try await store.prepare(item: story, scope: .track("one"))
        XCTAssertFalse(track.hasText); XCTAssertEqual(track.added, 0)
        try await store.complete(track, context: db.mainContext)
        XCTAssertTrue(story.tracks[0].isCompleted); XCTAssertFalse(story.isBookCompleted)
        XCTAssertTrue(store.forms(for: "pl").isEmpty)
        let chapter = try await store.prepare(item: story, scope: .track("two"))
        try await store.complete(chapter, context: db.mainContext)
        XCTAssertFalse(story.isBookCompleted)
        let book = try await store.prepare(item: story, scope: .book)
        XCTAssertEqual(book.added, 1)
        try await store.complete(book, context: db.mainContext)
        XCTAssertEqual(store.forms(for: "pl"), ["kot", "pies", "koń"])
    }

    @MainActor func testChangedKnowledgeOrTextRequiresNewConfirmation() async throws {
        let db = try container(), store = ReadingVocabularyStore()
        let story = try item(db.mainContext, text: "kot pies")
        await store.start(context: db.mainContext)
        let proposal = try await store.prepare(item: story, scope: .book)
        db.mainContext.insert(ReadVocabularyWord(languageCode: "pl", normalizedForm: "kot"))
        try db.mainContext.save(); try store.reload(context: db.mainContext)
        do { try await store.complete(proposal, context: db.mainContext); XCTFail("Stale confirmation accepted") } catch { }
        XCTAssertFalse(story.isBookCompleted)
        let updated = try await store.prepare(item: story, scope: .book)
        story.segments = [.init(start: nil, end: nil, text: "koń")]; try db.mainContext.save()
        do { try await store.complete(updated, context: db.mainContext); XCTFail("Changed text accepted") } catch { }
        XCTAssertFalse(story.isBookCompleted)
    }

    @MainActor func testSaveFailureRollsBackCompletionAndWordsButKeepsPriorPosition() async throws {
        let db = try container()
        let store = ReadingVocabularyStore(commitSave: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        let story = try item(db.mainContext, text: "kot")
        await store.start(context: db.mainContext)
        let proposal = try await store.prepare(item: story, scope: .book)
        story.lastPosition = 7
        do { try await store.complete(proposal, context: db.mainContext); XCTFail("Expected failure") } catch { }
        XCTAssertFalse(story.isBookCompleted)
        XCTAssertEqual(story.lastPosition, 7)
        XCTAssertEqual(try ReadingKnowledge.words(context: db.mainContext).count, 0)
        XCTAssertTrue(store.forms(for: "pl").isEmpty)
    }

    @MainActor func testHistoricalPartMigrationIsIdempotentWithoutInferringBookCompletion() async throws {
        let db = try container(), store = ReadingVocabularyStore()
        let story = try item(db.mainContext)
        story.segments = [.init(start: 0, end: 5, text: "Kot"), .init(start: 5, end: 10, text: "pies")]
        story.parts = [.init(start: 0, end: 5, isCompleted: true), .init(start: 5, end: 10)]
        story.readingVocabularyMigrationVersion = 0; try db.mainContext.save()
        await store.start(context: db.mainContext)
        XCTAssertTrue(store.ready)
        XCTAssertEqual(store.forms(for: "pl"), ["kot"])
        XCTAssertFalse(story.isBookCompleted)
        XCTAssertEqual(story.readingVocabularyMigrationVersion, 1)
        await store.start(context: db.mainContext)
        XCTAssertEqual(try ReadingKnowledge.words(context: db.mainContext).count, 1)
    }

    @MainActor func testMissingDeclaredSubtitleDoesNotPartiallyCompleteBook() async throws {
        let db = try container(), store = ReadingVocabularyStore()
        let story = try item(db.mainContext)
        story.tracks = [.init(id: "a", title: "A", mediaFilename: "a.wav", subtitleFilename: "missing.srt", duration: 10)]
        let directory = MediaImportService.directory(for: story.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "kot".write(to: directory.appending(path: story.transcriptFilename), atomically: true, encoding: .utf8)
        try db.mainContext.save(); await store.start(context: db.mainContext)
        do { _ = try await store.prepare(item: story, scope: .book); XCTFail("Missing declared file accepted") } catch { }
        XCTAssertFalse(story.isBookCompleted); XCTAssertTrue(store.forms(for: "pl").isEmpty)
    }

    @MainActor func testBackupRoundTripUnionAndTranslationsOnly() throws {
        let db = try container()
        let first = ReadVocabularyWord(languageCode: "pl", normalizedForm: "kot", firstLearnedAt: Date(timeIntervalSince1970: 10))
        let file = try DictionaryTransferService.export(entries: [], includeContext: true, readingWords: [first])
        let doc = try DictionaryTransferService.decode(file.data)
        XCTAssertEqual(doc.schemaVersion, 3)
        let existing = ReadVocabularyWord(languageCode: "pl", normalizedForm: "kot", firstLearnedAt: Date(timeIntervalSince1970: 20))
        let unrelated = ReadVocabularyWord(languageCode: "en", normalizedForm: "cat")
        db.mainContext.insert(existing); db.mainContext.insert(unrelated); try db.mainContext.save()
        for mode in [DictionaryImportMode.translations, .restore, .merge] {
            let local = try db.mainContext.fetch(FetchDescriptor<ReadVocabularyWord>())
            let preview = DictionaryTransferService.preview(document: doc, mode: mode, existing: [], existingVocabulary: local)
            _ = try DictionaryTransferService.apply(preview, context: db.mainContext)
            XCTAssertEqual(existing.firstLearnedAt, Date(timeIntervalSince1970: mode == .translations ? 20 : 10))
        }
        XCTAssertEqual(try ReadingKnowledge.words(context: db.mainContext).count, 2)
        let fresh = try container()
        let preview = DictionaryTransferService.preview(document: doc, mode: .restore, existing: [], existingVocabulary: [])
        _ = try DictionaryTransferService.apply(preview, context: fresh.mainContext)
        XCTAssertEqual(try ReadingKnowledge.words(context: fresh.mainContext).count, 1)
        XCTAssertEqual(try fresh.mainContext.fetchCount(FetchDescriptor<LearningItem>()), 0)
    }

    @MainActor func testBackupCommitFailureRollsBackBothDictionaryAndVocabulary() throws {
        let db = try container()
        let source = try item(db.mainContext)
        let entry = DictionaryEntry(text: "kot", item: source, segmentIndex: nil)
        let file = try DictionaryTransferService.export(entries: [entry], includeContext: true,
            readingWords: [ReadVocabularyWord(languageCode: "pl", normalizedForm: "kot")])
        let preview = DictionaryTransferService.preview(document: try DictionaryTransferService.decode(file.data), mode: .restore, existing: [], existingVocabulary: [])
        XCTAssertThrowsError(try DictionaryTransferService.apply(preview, context: db.mainContext, commitSave: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertEqual(try db.mainContext.fetchCount(FetchDescriptor<DictionaryEntry>()), 0)
        XCTAssertEqual(try ReadingKnowledge.words(context: db.mainContext).count, 0)
    }

    @MainActor func testBackupFailureRestoresExistingFieldsAndKnownWordDates() throws {
        let db = try container()
        let source = try item(db.mainContext)
        let entry = DictionaryEntry(text: "kot", item: source, segmentIndex: nil)
        entry.learningLevel = 4; entry.userNote = "backup note"
        let word = ReadVocabularyWord(languageCode: "pl", normalizedForm: "kot", firstLearnedAt: Date(timeIntervalSince1970: 10))
        let file = try DictionaryTransferService.export(entries: [entry], includeContext: true, readingWords: [word])
        entry.learningLevel = 1; entry.userNote = "local note"
        word.firstLearnedAt = Date(timeIntervalSince1970: 20)
        db.mainContext.insert(entry); db.mainContext.insert(word); try db.mainContext.save()
        let doc = try DictionaryTransferService.decode(file.data)
        let preview = DictionaryTransferService.preview(document: doc, mode: .restore, existing: [entry], existingVocabulary: [word])
        XCTAssertThrowsError(try DictionaryTransferService.apply(preview, context: db.mainContext, commitSave: { _ in throw CocoaError(.fileWriteOutOfSpace) }))
        XCTAssertEqual(entry.learningLevel, 1)
        XCTAssertEqual(entry.userNote, "local note")
        XCTAssertEqual(word.firstLearnedAt, Date(timeIntervalSince1970: 20))
    }

    @MainActor func testBackupValidationAndLegacyCompatibility() throws {
        let db = try container()
        let file = try DictionaryTransferService.export(entries: [], includeContext: true,
            readingWords: [ReadVocabularyWord(languageCode: "pl", normalizedForm: "kot")])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: file.data) as? [String: Any])
        for field in ["duplicate", "uppercase", "version", "missing", "language"] {
            var root = original
            var vocabulary = root["readingVocabulary"] as! [String: Any]
            var words = vocabulary["words"] as! [[String: Any]]
            switch field {
            case "duplicate": words += words
            case "uppercase": words[0]["normalizedForm"] = "KOT"
            case "version": vocabulary["tokenizerVersion"] = 2
            case "language": words[0]["languageCode"] = "PL"
            default: break
            }
            vocabulary["words"] = words; root["readingVocabulary"] = vocabulary
            if field == "missing" { root.removeValue(forKey: "readingVocabulary") }
            XCTAssertThrowsError(try DictionaryTransferService.decode(JSONSerialization.data(withJSONObject: root)), field)
        }
        for version in [1, 2] {
            var root = original; root["schemaVersion"] = version; root.removeValue(forKey: "readingVocabulary")
            let document = try DictionaryTransferService.decode(JSONSerialization.data(withJSONObject: root))
            db.mainContext.insert(ReadVocabularyWord(languageCode: "pl", normalizedForm: "pies")); try db.mainContext.save()
            _ = try DictionaryTransferService.apply(.init(document: document, mode: .restore, additions: 0, translationChanges: 0, unchanged: 0, conflicts: 0, skipped: 0), context: db.mainContext)
            XCTAssertEqual(try ReadingKnowledge.words(context: db.mainContext).count, 1)
            for word in try db.mainContext.fetch(FetchDescriptor<ReadVocabularyWord>()) { db.mainContext.delete(word) }; try db.mainContext.save()
        }
    }

    @MainActor func testEditorialTypographySurvivesDocumentReplacementWithoutChangingRanges() throws {
        let first = TranscriptDocument(segments: [.init(start: 0, end: 2, text: "Zażółć 🌍 gęślą jaźń.")])
        var parent = TranscriptTextView(document: first, activeSegment: 0,
            following: .constant(false), followGeneration: 0, onSelectionBegan: {},
            handleSelection: { _, _, _, _, _ in })
        let coordinator = parent.makeCoordinator()
        let view = TranscriptTextView.makeTextView(frame: CGRect(x: 0, y: 0, width: 1024, height: 700))
        coordinator.apply(to: view)
        view.layoutIfNeeded()
        let font = try XCTUnwrap(view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.fontDescriptor.withDesign(.serif)?.postscriptName, font.fontDescriptor.postscriptName)
        let paragraph = try XCTUnwrap(view.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(paragraph.lineSpacing, 0)
        XCTAssertGreaterThan(paragraph.paragraphSpacing, paragraph.lineSpacing)
        XCTAssertEqual(view.text, first.text)
        XCTAssertEqual((view.text as NSString).substring(with: first.ranges[0]), first.segments[0].text)
        XCTAssertEqual(view.bounds.width - view.textContainerInset.left - view.textContainerInset.right, 680, accuracy: 1)
        let second = TranscriptDocument(segments: [.init(start: 2, end: 4, text: "Nowy rozdział.")])
        parent = TranscriptTextView(document: second, activeSegment: 0,
            following: .constant(false), followGeneration: 0, onSelectionBegan: {},
            handleSelection: { _, _, _, _, _ in })
        coordinator.parent = parent
        coordinator.apply(to: view)
        XCTAssertEqual(view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont, font)
        XCTAssertNotNil(view.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil))
        XCTAssertEqual(view.text, second.text)
    }

    @MainActor func testEditorialTypographyScalesForAccessibilitySizes() {
        let regular = UITraitCollection(preferredContentSizeCategory: .large)
        let accessible = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        XCTAssertGreaterThan(ReadingTypography.font(compatibleWith: accessible).pointSize,
                             ReadingTypography.font(compatibleWith: regular).pointSize)
        XCTAssertGreaterThan(ReadingTypography.paragraph(compatibleWith: accessible).lineSpacing,
                             ReadingTypography.paragraph(compatibleWith: regular).lineSpacing)
    }

    @MainActor func testWordForegroundSurvivesCueChangesAndSelectionDefersUpdates() throws {
        let document = TranscriptDocument(segments: [.init(start: 0, end: 2, text: "Kot pies"), .init(start: 2, end: 4, text: "śpi")])
        var parent = TranscriptTextView(document: document, activeSegment: 0, following: .constant(false), followGeneration: 0,
            onSelectionBegan: {}, unknownWordRanges: [NSRange(location: 4, length: 4)], wordStyleRevision: 1,
            handleSelection: { _, _, _, _, _ in })
        let coordinator = parent.makeCoordinator()
        let view = TranscriptTextView.makeTextView()
        let renderer = try XCTUnwrap(view.layoutManager as? TranscriptLayoutManager)
        view.text = document.text; coordinator.apply(to: view)
        XCTAssertEqual(renderer.unknownRanges, [NSRange(location: 4, length: 4)])
        XCTAssertEqual(renderer.activeRange, document.ranges[0])
        parent = TranscriptTextView(document: document, activeSegment: 1, following: .constant(false), followGeneration: 0,
            onSelectionBegan: {}, unknownWordRanges: [], wordStyleRevision: 2, handleSelection: { _, _, _, _, _ in })
        view.selectedRange = NSRange(location: 4, length: 4)
        coordinator.parent = parent; coordinator.apply(to: view)
        XCTAssertEqual(view.selectedRange, NSRange(location: 4, length: 4))
        view.selectedRange = NSRange(location: 0, length: 0); coordinator.apply(to: view)
        XCTAssertEqual(renderer.activeRange, document.ranges[1])
        XCTAssertTrue(renderer.unknownRanges.isEmpty)
    }

    @MainActor func testViewportDecorationDoesNotEditTextStorageOrMoveScrollPosition() throws {
        let document = TranscriptDocument(segments: (0..<200).map {
            .init(start: Double($0), end: Double($0 + 1), text: "Kot pies śpi. Kot pies śpi. Kot pies śpi.")
        })
        let index = try VocabularyTokenizer.textIndex(in: document.text)
        var parent = TranscriptTextView(document: document, activeSegment: 0, following: .constant(false), followGeneration: 0,
            onSelectionBegan: {}, vocabularyIndex: index, handleSelection: { _, _, _, _, _ in })
        let view = TranscriptTextView.makeTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let coordinator = parent.makeCoordinator()
        coordinator.apply(to: view)
        view.layoutIfNeeded()
        let original = NSAttributedString(attributedString: view.textStorage)
        for step in 1...20 {
            view.setContentOffset(CGPoint(x: 0, y: step * 50), animated: false)
            let position = view.contentOffset
            parent.wordStyleRevision = step
            parent.knownForms = step.isMultiple(of: 2) ? ["kot"] : []
            coordinator.parent = parent
            coordinator.updateWordStyles(in: view)
            view.layoutIfNeeded()
            XCTAssertEqual(view.contentOffset.y, position.y, accuracy: 1)
            XCTAssertEqual(view.textStorage, original, "Color/underline updates must not edit storage and invalidate TextKit layout during scrolling")
        }
    }

    @MainActor func testPaintLayerActuallyRendersWordColorAndCueBackground() throws {
        let view = TranscriptTextView.makeTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        view.backgroundColor = .white
        view.textColor = .black
        view.font = .systemFont(ofSize: 24)
        view.text = "Kot pies"
        view.layoutIfNeeded()
        let manager = try XCTUnwrap(view.layoutManager as? TranscriptLayoutManager)
        let storage = NSAttributedString(attributedString: view.textStorage)
        func render() -> Data? {
            UIGraphicsImageRenderer(size: view.bounds.size).image { context in
                view.layer.render(in: context.cgContext)
            }.pngData()
        }
        let plain = try XCTUnwrap(render())
        manager.setWords([NSRange(location: 4, length: 4)], underline: false)
        view.setNeedsDisplay(); view.layoutIfNeeded()
        let colored = try XCTUnwrap(render())
        XCTAssertNotEqual(colored, plain, "The paint layer must visibly tint unknown words")
        manager.setWords([NSRange(location: 4, length: 4)], underline: true)
        view.setNeedsDisplay(); view.layoutIfNeeded()
        let underlined = try XCTUnwrap(render())
        XCTAssertNotEqual(underlined, colored, "Accessibility underline must render independently of color")
        manager.setActiveRange(NSRange(location: 0, length: 8))
        view.setNeedsDisplay(); view.layoutIfNeeded()
        let highlighted = try XCTUnwrap(render())
        XCTAssertNotEqual(highlighted, underlined)
        XCTAssertEqual(view.textStorage, storage)
        manager.clearDecorations()
        view.setNeedsDisplay(); view.layoutIfNeeded()
        XCTAssertEqual(render(), plain, "Removing paint must restore the original rendering")
    }

    func testZIPAndExternalTranscriptPreviewRemainReadOnlyAndDetectChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appending(path: "text.txt")
        try "Kot i kot pies".write(to: textURL, atomically: true, encoding: .utf8)
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
            buffer.frameLength = 8000
            let file = try AVAudioFile(forWriting: directory.appending(path: "media.wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        for strict in [false, true] {
            let service = BookImportService()
            let zip = directory.appending(path: strict ? "strict.zip" : "raw.zip")
            let archive = try Archive(url: zip, accessMode: .create)
            try archive.addEntry(with: "text.txt", relativeTo: directory)
            try archive.addEntry(with: "media.wav", relativeTo: directory)
            if strict {
                let manifest = BookManifest(format: BookManifest.formatIdentifier, schemaVersion: 1, title: "Book", sourceLanguage: "pl", transcript: "text.txt",
                    tracks: [.init(id: "one", title: "One", audio: "media.wav", alignmentStatus: .untimed, subtitle: nil, textRange: nil)], textMapping: nil)
                try JSONEncoder().encode(manifest).write(to: directory.appending(path: "manifest.json"))
                try archive.addEntry(with: "manifest.json", relativeTo: directory)
            }
            let preview = try await service.previewArchive(zip)
            let stats = try await service.vocabularyPreview(preview, transcriptPath: preview.selectedTranscript, externalTranscript: nil)
            XCTAssertEqual(stats.words, ["kot", "i", "pies"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: MediaImportService.directory(for: preview.itemID).path))
            let external = directory.appending(path: "external.txt")
            try "Kot koń".write(to: external, atomically: true, encoding: .utf8)
            let first = try await service.vocabularyPreview(preview, transcriptPath: nil, externalTranscript: external)
            try "Pies śpi".write(to: external, atomically: true, encoding: .utf8)
            let changed = try await service.vocabularyPreview(preview, transcriptPath: nil, externalTranscript: external)
            XCTAssertNotEqual(first.fingerprint, changed.fingerprint)
            XCTAssertEqual(changed.words, ["pies", "śpi"])
            let prepared = try await service.prepare(preview, title: "Book", sourceLanguage: "pl", orderedTracks: preview.tracks, transcriptPath: preview.selectedTranscript, externalTranscript: nil)
            let staged = try await service.vocabularyPreview(prepared)
            XCTAssertEqual(staged.fingerprint, stats.fingerprint)
            await service.cancel(preview)
        }
    }

    func testSingleSubtitleImportCountsOnlyParsedTextAndEnforcesLimit() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: url) }
        try "1\n00:00:00,000 --> 00:00:01,000\n<i>Kot</i> i kot.\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try VocabularyImportPreview.file(url).words, ["kot", "i"])
        XCTAssertThrowsError(try VocabularyImportPreview.file(url, limit: 5))
        try Data([0xff, 0xfe]).write(to: url)
        XCTAssertThrowsError(try VocabularyImportPreview.file(url))
    }

    @MainActor func testHundredTrackBookPreparationAndAtomicCommit() async throws {
        let db = try container(), store = ReadingVocabularyStore()
        let story = try item(db.mainContext)
        let directory = MediaImportService.directory(for: story.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = String(repeating: "Kot kota i pies śpi. ", count: 450_000)
        try text.write(to: directory.appending(path: story.transcriptFilename), atomically: true, encoding: .utf8)
        story.tracks = try (0..<100).map { index in
            let filename = "\(index).srt"
            try "1\n00:00:00,000 --> 00:00:01,000\nKot koń\n".write(to: directory.appending(path: filename), atomically: true, encoding: .utf8)
            return LearningTrack(id: "\(index)", title: "\(index)", mediaFilename: "media.wav", subtitleFilename: filename, duration: 10)
        }
        try db.mainContext.save(); await store.start(context: db.mainContext)
        let start = Date()
        let proposal = try await store.prepare(item: story, scope: .book)
        let preparedAt = Date()
        try await store.complete(proposal, context: db.mainContext)
        print("Reading vocabulary 100-track benchmark: \(text.utf8.count) TXT bytes, prepare=\(preparedAt.timeIntervalSince(start))s, revalidate+commit=\(Date().timeIntervalSince(preparedAt))s")
        XCTAssertEqual(store.forms(for: "pl").count, 6)
        XCTAssertTrue(story.tracks.allSatisfy(\.isCompleted))
        XCTAssertTrue(story.isBookCompleted)
    }

    func testLargeTextUsesUniqueSetsAndCancellation() async throws {
        let text = String(repeating: "Kot kota i pies śpi. ", count: 100_000)
        let start = Date()
        let forms = try VocabularyTokenizer.forms(in: text)
        XCTAssertEqual(forms.count, 5)
        print("Reading vocabulary: \(text.utf8.count) bytes indexed in \(Date().timeIntervalSince(start)) seconds")
        let task = Task.detached { try VocabularyTokenizer.occurrences(in: text) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled tokenization succeeded") } catch is CancellationError { }
    }
}
