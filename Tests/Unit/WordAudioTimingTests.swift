import Foundation
import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class WordAudioTimingTests: XCTestCase {
    private let audioHash = String(repeating: "a", count: 64)

    private func document(_ text: String = "Przewędrował ulicami ładnych parę kilometrów; owrzodzona noga coraz bardziej") throws -> TranscriptDocument {
        let document = TranscriptDocument(segments: [.init(start: 22, end: 26.56, text: text)])
        let words = text.split(whereSeparator: \.isWhitespace).enumerated().map { index, text in
            WordAudioTimingFile.Word(text: String(text), start: 22 + Double(index) * 0.5, end: 22.4 + Double(index) * 0.5)
        }
        let file = WordAudioTimingFile(schemaVersion: 1, trackID: "008", audioSHA256: audioHash,
                                       textSHA256: BookTextNormalization.sha256(try BookTextNormalization.normalize(text)), words: words)
        return try file.applying(to: document, trackID: "008", duration: 30)
    }

    func testWholeSentenceIncludesSurroundingWordsButNotNextSentence() throws {
        let doc = try document("To jest noga. Potem idziemy dalej.")
        let selected = (doc.text as NSString).range(of: "noga")
        XCTAssertEqual(PhraseAudioTiming.range(for: selected, in: doc, duration: 30), 23...23.4)
        XCTAssertEqual(PhraseAudioTiming.sentenceRange(for: selected, in: doc, duration: 30), 22...23.4)
    }

    @MainActor
    func testAudioModesHaveIndependentOverridesAndLegacyHasNoSentence() {
        let item = LearningItem(id: UUID(), title: "Story", mediaKind: "audio", mediaFilename: "a.m4a",
            transcriptFilename: "a.srt", duration: 20, segments: [])
        let entry = DictionaryEntry(text: "word", item: item, segmentIndex: nil, audioStart: 3, audioEnd: 4)
        XCTAssertNil(PhraseAudioSourceResolver.resolve(entry: entry, items: [item], mode: .sentence, fileExists: { _ in true }))
        entry.phraseAudioStart = 1
        entry.phraseAudioEnd = 8
        entry.manualAudioStart = 2.5
        entry.manualAudioEnd = 4.5
        entry.manualPhraseAudioStart = 0.5
        entry.manualPhraseAudioEnd = 9
        XCTAssertEqual(PhraseAudioSourceResolver.resolve(entry: entry, items: [item], fileExists: { _ in true })?.identity.range, 2.5...4.5)
        XCTAssertEqual(PhraseAudioSourceResolver.resolve(entry: entry, items: [item], mode: .sentence, fileExists: { _ in true })?.identity.range, 0.5...9)
        XCTAssertEqual(PhraseAudioSourceResolver.resolve(entry: entry, items: [item], mode: .sentence, ignoreManualRange: true, fileExists: { _ in true })?.identity.range, 0.5...8.5)
        XCTAssertEqual(entry.manualAudioStart, 2.5)
    }

    @MainActor func testAutomaticPaddingClampsToMediaAndManualRangesStayExact() {
        let item = LearningItem(id: UUID(), title: "Short", mediaKind: "audio", mediaFilename: "a.wav",
            transcriptFilename: "a.srt", duration: 2, segments: [])
        let entry = DictionaryEntry(text: "word", item: item, segmentIndex: nil, audioStart: 0.2, audioEnd: 1.8)
        entry.phraseAudioStart = 0
        entry.phraseAudioEnd = 2
        for mode in PhraseAudioMode.allCases {
            XCTAssertEqual(PhraseAudioSourceResolver.resolve(entry: entry, items: [item], mode: mode,
                fileExists: { _ in true })?.identity.range, 0...2)
        }
        entry.manualAudioStart = 0.3
        entry.manualAudioEnd = 1.7
        XCTAssertEqual(PhraseAudioSourceResolver.resolve(entry: entry, items: [item],
            fileExists: { _ in true })?.identity.range, 0.3...1.7)
        XCTAssertEqual(entry.audioStart, 0.2)
        XCTAssertEqual(entry.audioEnd, 1.8)
    }

    func testSelectedWordsExcludeFivePrecedingAndTwoFollowingWords() throws {
        let doc = try document()
        let selection = (doc.text as NSString).range(of: "owrzodzona noga")
        XCTAssertEqual(PhraseAudioTiming.range(for: selection, in: doc, duration: 30), 24.5...25.4)
        XCTAssertEqual(PhraseAudioTiming.savedSelection(selectedText: "owrzodzona noga", firstSegment: 0,
                                                        document: doc, storedRange: 22...26.56), selection)
    }

    func testRepeatedPhraseUsesSavedPreciseRangeOrStaysAmbiguous() throws {
        let doc = try document("noga noga")
        XCTAssertNil(PhraseAudioTiming.savedSelection(selectedText: "noga", firstSegment: 0, document: doc, storedRange: 22...26.56))
        XCTAssertEqual(PhraseAudioTiming.savedSelection(selectedText: "noga", firstSegment: 0, document: doc, storedRange: 22.5...22.9), NSRange(location: 5, length: 4))
        XCTAssertNil(PhraseAudioTiming.savedSelection(selectedText: "oga", firstSegment: 0, document: doc, storedRange: 22...26.56))
    }

    func testUnicodeNewlinesAndSelectionAcrossCues() throws {
        let raw = TranscriptDocument(segments: [.init(start: 1, end: 3, text: "Zażółć 👩🏽‍🚀"), .init(start: 4, end: 7, text: "gęślą\njaźń.")])
        let file = WordAudioTimingFile(schemaVersion: 1, trackID: "a", audioSHA256: audioHash,
            textSHA256: BookTextNormalization.sha256(try BookTextNormalization.normalize(raw.text)),
            words: [.init(text: "Zażółć", start: 1, end: 2), .init(text: "👩🏽‍🚀", start: 2, end: 3),
                    .init(text: "gęślą", start: 4, end: 5), .init(text: "jaźń.", start: 5, end: 6)])
        let doc = try file.applying(to: raw, trackID: "a", duration: 7)
        let selection = NSUnionRange((doc.text as NSString).range(of: "Zażółć"), (doc.text as NSString).range(of: "gęślą"))
        XCTAssertEqual(PhraseAudioTiming.range(for: selection, in: doc, duration: 7), 1...5)
        XCTAssertEqual(PhraseAudioTiming.range(for: (doc.text as NSString).range(of: "jaźń"), in: doc, duration: 7), 5...6)
    }

    func testSavedSelectionSearchStopsNearCueEvenInLongChapter() {
        let first = TranscriptSegment(start: 0, end: 1, text: "first word")
        let tail = (1...30_000).map { TranscriptSegment(start: Double($0), end: Double($0 + 1), text: "word word word") }
        let document = TranscriptDocument(segments: [first] + tail)
        XCTAssertEqual(PhraseAudioTiming.selectionSearchRange(firstSegment: 0, wordCount: 1, document: document),
                       document.ranges[0])
        let expected = NSRange(location: 6, length: 4)
        measure {
            for _ in 0..<100 {
                XCTAssertEqual(PhraseAudioTiming.savedSelection(selectedText: "word", firstSegment: 0,
                    document: document, storedRange: 0...1), expected)
            }
        }
    }

    func testBoundedSearchPreservesWhitespaceAndCrossCueSelections() {
        let document = TranscriptDocument(segments: [
            .init(start: 0, end: 1, text: "Before first"),
            .init(start: 1, end: 2, text: "  \t"),
            .init(start: 2, end: 3, text: "second"),
            .init(start: 3, end: 4, text: "third after"),
            .init(start: 4, end: 5, text: "first second third")])
        let expected = NSRange(location: 7, length: document.ranges[3].location + "third".utf16.count - 7)
        let selection = PhraseAudioTiming.savedSelection(selectedText: "first second third", firstSegment: 0,
            document: document, storedRange: 0...4)
        XCTAssertEqual(selection, expected)
        XCTAssertEqual(PhraseAudioTiming.removingLegacyPadding(from: 0...4.5, selectedText: "first second third",
            firstSegment: 0, document: document), 0...4)
    }

    func testZeroDurationSpokenWordFallsBackToCueButPunctuationDoesNot() throws {
        let raw = TranscriptDocument(segments: [.init(start: 1, end: 8, text: "— owrzodzona noga")])
        func aligned(_ end: Double) throws -> TranscriptDocument {
            let file = WordAudioTimingFile(schemaVersion: 1, trackID: "a", audioSHA256: audioHash,
                textSHA256: BookTextNormalization.sha256("— owrzodzona noga"), words: [
                    .init(text: "—", start: 1, end: 1), .init(text: "owrzodzona", start: 2, end: end), .init(text: "noga", start: 4, end: 5)])
            return try file.applying(to: raw, trackID: "a", duration: 8)
        }
        let selection = NSRange(location: 0, length: (raw.text as NSString).length)
        XCTAssertEqual(PhraseAudioTiming.range(for: selection, in: try aligned(3), duration: 8), 2...5)
        XCTAssertNil(PhraseAudioTiming.wordRange(for: selection, in: try aligned(2), duration: 8))
        XCTAssertEqual(PhraseAudioTiming.range(for: selection, in: try aligned(2), duration: 8), 1...8)
    }

    func testRejectsWrongTrackTextInvalidTimesAndMissingTokens() throws {
        let raw = TranscriptDocument(segments: [.init(start: 0, end: 4, text: "one two")])
        func file(track: String = "a", hash: String? = nil, words: [WordAudioTimingFile.Word]) -> WordAudioTimingFile {
            .init(schemaVersion: 1, trackID: track, audioSHA256: audioHash,
                  textSHA256: hash ?? BookTextNormalization.sha256("one two"), words: words)
        }
        let valid = [WordAudioTimingFile.Word(text: "one", start: 0, end: 1), .init(text: "two", start: 1, end: 2)]
        XCTAssertThrowsError(try file(track: "b", words: valid).applying(to: raw, trackID: "a", duration: 4))
        XCTAssertThrowsError(try file(hash: audioHash, words: valid).applying(to: raw, trackID: "a", duration: 4))
        XCTAssertThrowsError(try file(words: Array(valid.prefix(1))).applying(to: raw, trackID: "a", duration: 4))
        for times in [(-1.0, 1.0), (2, 1), (1, 5), (.nan, 2), (0.5, 2)] {
            let words = [valid[0], WordAudioTimingFile.Word(text: "two", start: times.0, end: times.1)]
            XCTAssertThrowsError(try file(words: words).applying(to: raw, trackID: "a", duration: 4))
        }
    }

    @MainActor func testOldDictionaryEntryAndPreviewUseWordTimesFromSameTrack() throws {
        let item = LearningItem(id: UUID(), title: "Book", mediaKind: "audio", mediaFilename: "", transcriptFilename: "transcript.txt", duration: 30, segments: [], tracks: [
            .init(id: "008", title: "Eight", mediaFilename: "008.mp3", subtitleFilename: "008.srt", duration: 30,
                  alignmentStatus: .aligned, wordTimingsFilename: "008.json")])
        let directory = MediaImportService.directory(for: item.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let doc = try document()
        try "1\n00:00:22,000 --> 00:00:26,560\n\(doc.text)\n".write(to: directory.appending(path: "008.srt"), atomically: true, encoding: .utf8)
        let words = doc.wordTimings.map { word in WordAudioTimingFile.Word(text: (doc.text as NSString).substring(with: word.range), start: word.start, end: word.end) }
        let file = WordAudioTimingFile(schemaVersion: 1, trackID: "008", audioSHA256: audioHash,
            textSHA256: BookTextNormalization.sha256(try BookTextNormalization.normalize(doc.text)), words: words)
        try JSONEncoder().encode(file).write(to: directory.appending(path: "008.json"))
        let entry = DictionaryEntry(text: "owrzodzona noga", item: item, segmentIndex: 0, audioStart: 22, audioEnd: 26.56, sourceTrackID: "008")
        let source = PhraseAudioSourceResolver.resolve(entry: entry, items: [item], fileExists: { _ in true })
        XCTAssertEqual(source?.identity.range, 24...25.9)
        XCTAssertEqual(source?.playLabel, "Play phrase")
        XCTAssertEqual(entry.audioStart, 22, "Old backup metadata is retained; the local word range is resolved at playback.")
        let preview = SelectionTranslationPreview(selectedText: entry.text, sourceLanguageCode: "pl", context: nil,
            sourceItemID: item.id, sourceTitle: item.title, audioRange: 24.5...25.4, sourceTrackID: "008", segmentIndex: 0)
        XCTAssertEqual(PhraseAudioSourceResolver.resolve(preview: preview, items: [item], fileExists: { _ in true })?.identity.range, 24...25.9)
        entry.sourceTrackID = "other"
        XCTAssertNil(PhraseAudioSourceResolver.resolve(entry: entry, items: [item], fileExists: { _ in true }))
    }

    func testLegacyTracksDecodeWithoutWordTimingFilename() throws {
        let track = try JSONDecoder().decode(LearningTrack.self, from: Data(#"{"id":"1","title":"One","mediaFilename":"1.mp3","duration":10,"alignmentStatus":"untimed","lastPosition":0,"isCompleted":false}"#.utf8))
        XCTAssertNil(track.wordTimingsFilename)
    }
}
