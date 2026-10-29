import Foundation
import SwiftData
import XCTest
@testable import ForeignLanguageLearner

final class PhraseAudioRequestTests: XCTestCase {
    @MainActor private func fixture() -> (LearningItem, DictionaryEntry) {
        let item = LearningItem(id: UUID(), title: "Book", mediaKind: "audio", mediaFilename: "a.wav",
            transcriptFilename: "a.srt", duration: 20, segments: [])
        let entry = DictionaryEntry(text: "word", item: item, segmentIndex: nil, audioStart: 3, audioEnd: 4)
        entry.phraseAudioStart = 1
        entry.phraseAudioEnd = 8
        return (item, entry)
    }

    @MainActor func testTypingSavingAndPlaybackProgressDoNotInvalidateAudioRequest() {
        let (item, entry) = fixture()
        item.tracks = [.init(id: "one", title: "One", mediaFilename: "a.wav", duration: 20)]
        let request = PhraseAudioRequest(entry: entry, items: [item])
        entry.translationText = "A different translation"
        entry.translationRevision += 1
        entry.userNote = "Typing a note"
        entry.selectedSenseText = "Typing a meaning"
        item.lastPosition = 10
        item.tracks[0].lastPosition = 10
        item.tracks[0].isCompleted = true
        XCTAssertEqual(request, PhraseAudioRequest(entry: entry, items: [item]))
    }

    @MainActor func testManualRangesModesAndResourceReplacementInvalidateRequest() {
        let (item, entry) = fixture()
        let request = PhraseAudioRequest(entry: entry, items: [item])
        XCTAssertNotEqual(request, PhraseAudioRequest(entry: entry, items: [item], mode: .sentence))
        entry.manualAudioStart = 2
        entry.manualAudioEnd = 5
        let manual = PhraseAudioRequest(entry: entry, items: [item])
        XCTAssertNotEqual(request, manual)
        XCTAssertEqual(manual.resolve(fileExists: { _ in true })?.identity.range, 2...5)
        XCTAssertEqual(request.resolve(fileExists: { _ in true })?.identity.range, 2.5...4.5,
                       "An in-flight worker must keep its original immutable inputs")
        XCTAssertEqual(PhraseAudioRequest(entry: entry, items: [item], ignoreManualRange: true)
            .resolve(fileExists: { _ in true })?.identity.range, 2.5...4.5)
        item.resourceRevision = UUID().uuidString
        XCTAssertNotEqual(manual, PhraseAudioRequest(entry: entry, items: [item]))
    }

    @MainActor func testTimingSidecarReplacementAndSourceDeletionInvalidateRequest() {
        let (item, entry) = fixture()
        item.tracks = [.init(id: "one", title: "One", mediaFilename: "a.wav", subtitleFilename: "one.srt", duration: 20)]
        entry.sourceTrackID = "one"
        let request = PhraseAudioRequest(entry: entry, items: [item])
        item.tracks[0].wordTimingsFilename = "new-word-timings.json"
        XCTAssertNotEqual(request, PhraseAudioRequest(entry: entry, items: [item]))
        let deleted = PhraseAudioRequest(entry: entry, items: [])
        XCTAssertNotEqual(request, deleted)
        XCTAssertNil(deleted.resolve(fileExists: { _ in true }))
    }

    @MainActor func testSnapshotResolvesOnWorkerAfterManagedValuesChange() async {
        let (item, entry) = fixture()
        let request = PhraseAudioRequest(entry: entry, items: [item])
        entry.audioStart = 9
        entry.audioEnd = 10
        item.mediaFilename = "replacement.wav"
        let source = await Task.detached { request.resolve(fileExists: { _ in true }) }.value
        XCTAssertEqual(source?.identity.range, 2.5...4.5)
        XCTAssertEqual(source?.identity.url.lastPathComponent, "a.wav")
    }

    @MainActor func testPreviewSnapshotPreservesSourceAndPadding() async {
        let (item, _) = fixture()
        let preview = SelectionTranslationPreview(selectedText: "word", sourceLanguageCode: "pl", context: nil,
            sourceItemID: item.id, sourceTitle: item.title, audioRange: 3...4)
        let request = PhraseAudioRequest(preview: preview, items: [item])
        let source = await Task.detached { request.resolve(fileExists: { _ in true }) }.value
        XCTAssertEqual(source?.identity.range, 2.5...4.5)
        XCTAssertEqual(source?.identity.itemID, item.id)
    }
}
