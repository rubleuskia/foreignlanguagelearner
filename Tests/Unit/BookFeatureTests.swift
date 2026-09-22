import Foundation
import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class BookFeatureTests: XCTestCase {
    func testTimelineUsesHalfOpenBoundariesAndExactTotal() throws {
        let timeline = try BookTimeline(tracks: [("one", 60), ("two", 90), ("three", 30)])
        XCTAssertEqual(try timeline.location(at: 0), .init(index: 0, trackID: "one", localTime: 0))
        XCTAssertEqual(try timeline.location(at: 59), .init(index: 0, trackID: "one", localTime: 59))
        XCTAssertEqual(try timeline.location(at: 60), .init(index: 1, trackID: "two", localTime: 0))
        XCTAssertEqual(try timeline.location(at: 149), .init(index: 1, trackID: "two", localTime: 89))
        XCTAssertEqual(try timeline.location(at: 150), .init(index: 2, trackID: "three", localTime: 0))
        XCTAssertEqual(try timeline.location(at: 180), .init(index: 2, trackID: "three", localTime: 30))
        XCTAssertEqual(try timeline.location(at: -1).localTime, 0)
        XCTAssertEqual(try timeline.location(at: 1_000).localTime, 30)
        XCTAssertThrowsError(try timeline.location(at: .nan))
        XCTAssertThrowsError(try timeline.location(at: .infinity))
    }

    func testTimelineKeepsFractionalPrecision() throws {
        let timeline = try BookTimeline(tracks: [("a", 0.125), ("b", 0.375)])
        XCTAssertEqual(timeline.offsets, [0, 0.125])
        XCTAssertEqual(timeline.total, 0.5)
        XCTAssertEqual(try timeline.location(at: 0.125).trackID, "b")
    }

    func testManifestOrderStatusAndUnknownFields() throws {
        let data = Data(#"""
        {
          "format":"foreign-language-learner.book","schemaVersion":1,
          "title":"Book","sourceLanguage":"pl","transcript":"transcript.txt",
          "tracks":[
            {"id":"10","title":"Ten","audio":"audio/10.mp3","alignmentStatus":"untimed"},
            {"id":"2","title":"Two","audio":"audio/2.mp3","alignmentStatus":"untimed"},
            {"id":"1","title":"One","audio":"audio/1.mp3","alignmentStatus":"untimed"}
          ]
        }
        """#.utf8)
        let manifest = try BookManifestValidator.decode(data)
        XCTAssertEqual(manifest.tracks.map(\.id), ["10", "2", "1"])
        let tracks = manifest.tracks.map {
            LearningTrack(id: $0.id, title: $0.title, mediaFilename: $0.audio,
                          duration: 1, alignmentStatus: $0.alignmentStatus)
        }
        XCTAssertEqual(BookSynchronizationState.resolve(tracks), .untimed)
        let typo = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"tracks\":", with: "\"extra\":true,\"tracks\":")
        XCTAssertThrowsError(try BookManifestValidator.decode(Data(typo.utf8)))
    }

    func testTextNormalizationMatchesBatchContract() throws {
        let input = "\u{FEFF}Za\u{006C}\u{0301}e\u{00A0}\r\n  emoji 👩🏽‍🚀\u{2009}powtórka powtórka"
        let normalized = try BookTextNormalization.normalize(input)
        XCTAssertEqual(normalized, "Zaĺe emoji 👩🏽‍🚀 powtórka powtórka")
        XCTAssertEqual(try BookTextNormalization.words(input).count, 5)
        XCTAssertEqual(BookTextNormalization.sha256(normalized).count, 64)
    }

    func testTextMappingRequiresCompleteContiguousCoverage() throws {
        let transcript = Data("one two three".utf8)
        let hash = BookTextNormalization.sha256("one two three")
        let json = #"""
        {
          "format":"foreign-language-learner.book","schemaVersion":1,"title":"Book",
          "sourceLanguage":"en","transcript":"transcript.txt",
          "textMapping":{"normalization":"aligner-nfc-whitespace-v1","normalizedSHA256":"\#(hash)","wordCount":3},
          "tracks":[
            {"id":"a","title":"A","audio":"a.mp3","alignmentStatus":"untimed","textRange":{"startWord":0,"endWord":1}},
            {"id":"b","title":"B","audio":"b.mp3","alignmentStatus":"untimed","textRange":{"startWord":1,"endWord":3}}
          ]
        }
        """#
        XCTAssertNoThrow(try BookManifestValidator.decode(Data(json.utf8), transcriptData: transcript))
        XCTAssertThrowsError(try BookManifestValidator.decode(Data(json.replacingOccurrences(of: "\"startWord\":1", with: "\"startWord\":2").utf8), transcriptData: transcript))
    }

    func testArchivePathValidationRejectsTraversalAndCollisions() {
        for path in ["../audio.mp3", "/audio.mp3", "C:/audio.mp3", "audio\\one.mp3", "a//b.mp3", "./a.mp3"] {
            XCTAssertThrowsError(try BookManifestValidator.validatePath(path))
        }
        XCTAssertNoThrow(try BookManifestValidator.validatePath("audio/one.mp3", extensions: ["mp3"]))
        XCTAssertEqual(BookManifestValidator.normalizedCollisionKey("A/CAFÉ.MP3"),
                       BookManifestValidator.normalizedCollisionKey("a/cafe\u{301}.mp3"))
    }

    @MainActor func testDescriptorNeverFallsBackToLegacyFilenameForBook() {
        let item = LearningItem(id: UUID(), title: "Book", mediaKind: "audio", mediaFilename: "",
                                transcriptFilename: "transcript.txt", duration: 20, segments: [],
                                tracks: [LearningTrack(id: "chapter", title: "Chapter",
                                                       mediaFilename: "audio/chapter.mp3", duration: 20)])
        let descriptor = BookMediaDescriptor(item: item)
        XCTAssertFalse(descriptor.isLegacy)
        XCTAssertNil(descriptor.track(id: nil))
        XCTAssertEqual(descriptor.track(id: "chapter")?.mediaFilename, "audio/chapter.mp3")
    }

    @MainActor func testPhraseAudioRequiresExactTrackForMultiTrackBooks() throws {
        let id = UUID()
        let directory = MediaImportService.directory(for: id)
        try FileManager.default.createDirectory(at: directory.appending(path: "audio"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appending(path: "audio/a.mp3"))
        try Data([2]).write(to: directory.appending(path: "audio/b.mp3"))
        let item = LearningItem(id: id, title: "Book", mediaKind: "audio", mediaFilename: "",
                                transcriptFilename: "transcript.txt", duration: 20, segments: [],
                                tracks: [
                                    LearningTrack(id: "a", title: "A", mediaFilename: "audio/a.mp3", duration: 10),
                                    LearningTrack(id: "b", title: "B", mediaFilename: "audio/b.mp3", duration: 10)
                                ])
        XCTAssertNil(PhraseAudioSourceResolver.resolve(
            localSourceItemID: id, sourceItemID: id, audioRange: 1...2,
            sourceTrackID: nil, items: [item]
        ))
        let first = try XCTUnwrap(PhraseAudioSourceResolver.resolve(
            localSourceItemID: id, sourceItemID: id, audioRange: 1...2,
            sourceTrackID: "a", items: [item]
        ))
        let second = try XCTUnwrap(PhraseAudioSourceResolver.resolve(
            localSourceItemID: id, sourceItemID: id, audioRange: 1...2,
            sourceTrackID: "b", items: [item]
        ))
        XCTAssertNotEqual(first.identity.url, second.identity.url)
        XCTAssertNotEqual(first.identity.trackID, second.identity.trackID)
        XCTAssertNil(PhraseAudioSourceResolver.resolve(
            localSourceItemID: id, sourceItemID: id, audioRange: 1...2,
            sourceTrackID: "missing", items: [item]
        ))
        XCTAssertNil(PhraseAudioSourceResolver.resolve(
            localSourceItemID: id, sourceItemID: id, audioRange: 9...11,
            sourceTrackID: "a", items: [item]
        ))
    }

    @MainActor func testLegacyAndBookValuesPersistToDiskAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "library.store")
        let configuration = ModelConfiguration(url: store)
        let legacyID = UUID(), bookID = UUID(), dictionaryID = UUID()
        do {
            let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                                               configurations: configuration)
            let legacy = LearningItem(id: legacyID, title: "Legacy", mediaKind: "video",
                                      mediaFilename: "media.mp4", transcriptFilename: "text.srt",
                                      duration: 100, segments: [.init(start: 2, end: 3, text: "old")],
                                      parts: [.init(start: 0, end: 100, isCompleted: true, lastPosition: 42)])
            legacy.lastPosition = 42
            let entry = DictionaryEntry(text: "old", item: legacy, segmentIndex: 0,
                                        audioStart: 2, audioEnd: 3)
            entry.id = dictionaryID
            let book = LearningItem(id: bookID, title: "Book", mediaKind: "audio", mediaFilename: "",
                                    transcriptFilename: "transcript.txt", duration: 20, segments: [],
                                    tracks: [LearningTrack(id: "one", title: "One",
                                                           mediaFilename: "audio/one.mp3", duration: 20,
                                                           lastPosition: 7)], lastTrackID: "one")
            container.mainContext.insert(legacy); container.mainContext.insert(entry); container.mainContext.insert(book)
            try container.mainContext.save()
        }
        let reopened = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                                          configurations: ModelConfiguration(url: store))
        let items = try reopened.mainContext.fetch(FetchDescriptor<LearningItem>())
        XCTAssertEqual(Set(items.map(\.id)), [legacyID, bookID])
        let legacy = try XCTUnwrap(items.first { $0.id == legacyID })
        XCTAssertEqual(legacy.mediaKind, "video")
        XCTAssertEqual(legacy.parts.first?.lastPosition, 42)
        XCTAssertTrue(legacy.tracks.isEmpty)
        let book = try XCTUnwrap(items.first { $0.id == bookID })
        XCTAssertEqual(book.tracks.first?.id, "one")
        XCTAssertEqual(book.tracks.first?.lastPosition, 7)
        XCTAssertEqual(try reopened.mainContext.fetch(FetchDescriptor<DictionaryEntry>()).first?.id, dictionaryID)
    }
}
