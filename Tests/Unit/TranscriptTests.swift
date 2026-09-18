import XCTest
import SwiftData
@testable import ForeignLanguageLearner

final class TranscriptTests: XCTestCase {
    func testSRTParsingSortsSegmentsAndHandlesCRLFAndUnicode() throws {
        let document = try TranscriptParser.parse("\u{FEFF}2\r\n00:00:03,000 --> 00:00:04,500\r\n世界 🌍\r\n\r\n1\r\n00:00:00,500 --> 00:00:02,000\r\nHello\r\nthere", extension: "srt")
        XCTAssertEqual(document.segments.map(\.text), ["Hello\nthere", "世界 🌍"])
        XCTAssertNil(document.activeSegment(at: 0))
        XCTAssertEqual(document.activeSegment(at: 0.5), 0)
        XCTAssertNil(document.activeSegment(at: 2))
        XCTAssertEqual(document.activeSegment(at: 3.2), 1)
        XCTAssertNil(document.activeSegment(at: 4.5))
        for (index, range) in document.ranges.enumerated() {
            XCTAssertEqual((document.text as NSString).substring(with: range), document.segments[index].text)
        }
    }

    func testWebVTTMetadataSettingsAndMarkup() throws {
        let input = "WEBVTT\n\nNOTE example\nignore this\n\nintro\n00:01.250 --> 00:03.000 align:start\n<v Speaker><b>Hello</b> &amp; goodbye\n\n00:04.000 --> 00:05.000\nNext"
        let document = try TranscriptParser.parse(input, extension: "vtt")
        XCTAssertEqual(document.segments.count, 2)
        XCTAssertEqual(document.segments[0].text, "Hello & goodbye")
        XCTAssertEqual(document.segments[0].start, 1.25)
    }

    func testInvalidSubtitlesAreRejected() {
        for input in ["", "1\nmissing times\nHello", "1\n00:00:03,000 --> 00:00:01,000\nHello", "1\n00:00:00,000 --> 00:00:01,000"] {
            XCTAssertThrowsError(try TranscriptParser.parse(input, extension: "srt"))
        }
        XCTAssertNil(TranscriptParser.timestamp("00:61:00.000"))
        XCTAssertNil(TranscriptParser.timestamp("00:00:nan"))
        XCTAssertNil(TranscriptParser.timestamp("00:-1.000"))
    }

    func testWhitespaceBetweenSubtitleBlocks() throws {
        let document = try TranscriptParser.parse("1\n00:00:00,000 --> 00:00:01,000\nFirst\n \t\n2\n00:00:01,000 --> 00:00:02,000\nSecond", extension: "srt")
        XCTAssertEqual(document.segments.count, 2)
    }

    func testPlainTextHasNoInventedTiming() throws {
        let document = try TranscriptParser.parse(" Hello\nworld ", extension: "txt")
        XCTAssertEqual(document.text, "Hello\nworld")
        XCTAssertNil(document.activeSegment(at: 1))
    }

    func testSeekBackwardAndOverlappingSegments() {
        let document = TranscriptDocument(segments: [
            .init(start: 0, end: 5, text: "First"),
            .init(start: 2, end: 6, text: "Second")
        ])
        XCTAssertEqual(document.activeSegment(at: 4), 1)
        XCTAssertEqual(document.activeSegment(at: 1), 0)
    }

    func testTranscriptDocumentPreservesAbsoluteSourceIndicesForFilteredParts() {
        let document = TranscriptDocument(
            segments: [
                .init(start: 10, end: 11, text: "Second"),
                .init(start: 11, end: 12, text: "Third")
            ],
            sourceIndices: [1, 2]
        )

        XCTAssertEqual(document.sourceIndices, [1, 2])
    }

    func testTranscriptContextKeepsExactRepeatedSelection() throws {
        let text = "Zamek jest stary. Zamek jest zepsuty. Koniec."
        let first = (text as NSString).range(of: "Zamek")
        let second = (text as NSString).range(of: "Zamek", options: [],
                                              range: NSRange(location: NSMaxRange(first),
                                                             length: (text as NSString).length - NSMaxRange(first)))

        let context = try XCTUnwrap(TranscriptTextView.Coordinator.context(in: text, selection: second))

        XCTAssertEqual((context.text as NSString).substring(with: context.selection), "Zamek")
        XCTAssertGreaterThan(context.selection.location, first.location)
    }

    func testPartPlannerUsesTimedCueBoundariesAndDoesNotCreatePartsForPlainText() {
        let segments = [TranscriptSegment(start: 0, end: 298, text: "One"), TranscriptSegment(start: 298, end: 603, text: "Two"), TranscriptSegment(start: 603, end: 900, text: "Three"), TranscriptSegment(start: 900, end: 1_201, text: "Four")]
        let parts = LearningPartPlanner.makeParts(segments: segments, duration: 1_201, targetDuration: 600)
        XCTAssertEqual(parts.map(\.start), [0, 603])
        XCTAssertEqual(parts.map(\.end), [603, 1_201])
        XCTAssertTrue(LearningPartPlanner.makeParts(segments: [.init(start: nil, end: nil, text: "Untimed")], duration: 1_201, targetDuration: 600).isEmpty)
    }

    func testPartProgressAndLookupArePersistentModelValues() {
        let item = LearningItem(id: UUID(), title: "Lesson", mediaKind: "audio", mediaFilename: "media.m4a", transcriptFilename: "transcript.srt", duration: 1_000, segments: [], parts: [LearningPart(start: 0, end: 600), LearningPart(start: 600, end: 1_000)])
        XCTAssertEqual(item.partIndex(containing: 650), 1)
        XCTAssertEqual(item.partIndex(containing: 1_000), 0)
        item.parts[0].isCompleted = true
        XCTAssertTrue(item.parts[0].isCompleted)
    }

    @MainActor func testPartCompletionAndPositionPersist() throws {
        let container = try ModelContainer(for: LearningItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let item = LearningItem(id: UUID(), title: "Lesson", mediaKind: "audio", mediaFilename: "media.m4a", transcriptFilename: "transcript.srt", duration: 1_000, segments: [], parts: [LearningPart(start: 0, end: 600, isCompleted: true, lastPosition: 242)])
        context.insert(item)
        try context.save()
        let saved = try context.fetch(FetchDescriptor<LearningItem>()).first!
        XCTAssertEqual(saved.parts, [LearningPart(id: saved.parts[0].id, start: 0, end: 600, isCompleted: true, lastPosition: 242)])
    }

    @MainActor func testDictionaryPersistsMultiwordSelectionAndSource() throws {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let item = LearningItem(id: UUID(), title: "Lesson", mediaKind: "audio", mediaFilename: "media.m4a", transcriptFilename: "transcript.srt", duration: 10, segments: [])
        let entry = DictionaryEntry(text: "  dzień\n dobry 🌍  ", item: item, segmentIndex: 2)
        context.insert(item)
        context.insert(entry)
        try context.save()
        let saved = try context.fetch(FetchDescriptor<DictionaryEntry>()).first!
        XCTAssertEqual(saved.text, "dzień dobry 🌍")
        XCTAssertEqual(saved.sourceItemID, item.id)
        XCTAssertEqual(saved.segmentIndex, 2)
    }

    @MainActor func testDictionaryPersistsAudioRange() throws {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let item = LearningItem(id: UUID(), title: "Lesson", mediaKind: "audio", mediaFilename: "media.m4a",
                                transcriptFilename: "transcript.srt", duration: 20,
                                segments: [.init(start: 4, end: 6, text: "dzień dobry")])
        let entry = DictionaryEntry(text: "dzień dobry", item: item, segmentIndex: 0,
                                    audioStart: 4, audioEnd: 6)
        context.insert(item)
        context.insert(entry)
        try context.save()

        let saved = try context.fetch(FetchDescriptor<DictionaryEntry>()).first!
        XCTAssertEqual(saved.audioStart, 4)
        XCTAssertEqual(saved.audioEnd, 6)
    }
}
