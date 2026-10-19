import Foundation
import SwiftData
import XCTest
import ZIPFoundation
@testable import ForeignLanguageLearner

@MainActor
final class WordTimingUpdateTests: XCTestCase {
    private func wave() -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let byteCount: UInt32 = 64_000
        text("RIFF"); u32(36 + byteCount); text("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16); text("data"); u32(byteCount)
        data.append(Data(repeating: 0, count: Int(byteCount)))
        return data
    }

    private func fixture(timingsOnly: Bool = false) throws -> (LearningItem, URL, URL) {
        let item = LearningItem(id: UUID(), title: "Existing", mediaKind: "audio", mediaFilename: "", transcriptFilename: "transcript.txt", duration: 2, segments: [], tracks: [
            .init(id: "001", title: "One", mediaFilename: "001.wav", subtitleFilename: "001.srt", duration: 2,
                  alignmentStatus: .aligned, lastPosition: 1.5, isCompleted: true)])
        let directory = MediaImportService.directory(for: item.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try wave().write(to: directory.appending(path: "001.wav"))
        let subtitle = "1\n00:00:00,000 --> 00:00:02,000\none two three\n"
        try subtitle.write(to: directory.appending(path: "001.srt"), atomically: true, encoding: .utf8)
        let source = directory.appending(path: "source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let timing = WordAudioTimingFile(schemaVersion: 1, trackID: "001",
            audioSHA256: try WordAudioTimingFile.audioHash(directory.appending(path: "001.wav")),
            textSHA256: BookTextNormalization.sha256("one two three"), words: [
                .init(text: "one", start: 0.1, end: 0.4), .init(text: "two", start: 0.6, end: 0.9), .init(text: "three", start: 1, end: 1.4)])
        try JSONEncoder().encode(timing).write(to: source.appending(path: "timings.json"))
        let manifest = BookManifest(format: BookManifest.formatIdentifier, schemaVersion: 1, title: "Book", sourceLanguage: "en", transcript: "transcript.txt", tracks: [
            .init(id: "001", title: "One", audio: "001.wav", alignmentStatus: .aligned, subtitle: "001.srt", textRange: nil, wordTimings: "timings.json")], textMapping: nil)
        try JSONEncoder().encode(manifest).write(to: source.appending(path: "manifest.json"))
        try "one two three".write(to: source.appending(path: "transcript.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: directory.appending(path: "001.wav"), to: source.appending(path: "001.wav"))
        try FileManager.default.copyItem(at: directory.appending(path: "001.srt"), to: source.appending(path: "001.srt"))
        let url = directory.appending(path: "update.book.zip")
        let archive = try Archive(url: url, accessMode: .create)
        let names = timingsOnly ? ["manifest.json", "timings.json"] : ["manifest.json", "timings.json", "001.wav", "001.srt", "transcript.txt"]
        for name in names {
            try archive.addEntry(with: name, relativeTo: source)
        }
        return (item, directory, url)
    }

    func testUpdatePreservesBookProgressAndUpdatesOldDictionaryAudio() async throws {
        let (item, directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = DictionaryEntry(text: "two", item: item, segmentIndex: 0, audioStart: 0, audioEnd: 2, sourceTrackID: "001")
        let prepared = try await WordTimingUpdateService().prepare(archiveURL: url, tracks: item.tracks, directory: directory)
        var saved = false
        let count = try WordTimingUpdateCommit.apply(prepared, to: item, entries: [entry]) { saved = true }
        XCTAssertTrue(saved)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(entry.audioStart, 0.6)
        XCTAssertEqual(entry.audioEnd, 0.9)
        XCTAssertEqual(entry.localSourceItemID, item.id)
        XCTAssertEqual(item.tracks[0].lastPosition, 1.5)
        XCTAssertTrue(item.tracks[0].isCompleted)
        XCTAssertNotNil(item.tracks[0].wordTimingsFilename)
    }

    func testSmallTimingOnlyArchiveUpdatesExistingBook() async throws {
        let (item, directory, url) = try fixture(timingsOnly: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prepared = try await WordTimingUpdateService().prepare(archiveURL: url, tracks: item.tracks, directory: directory)
        XCTAssertEqual(Set(prepared.filenames.keys), ["001"])
        XCTAssertEqual(item.tracks[0].wordTimingsFilename, nil, "Preparation must not publish model references.")
    }

    func testSaveFailureRestoresTrackAndDictionaryMetadata() async throws {
        let (item, directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = DictionaryEntry(text: "two", item: item, segmentIndex: 0, audioStart: 0, audioEnd: 2, sourceTrackID: "001")
        let prepared = try await WordTimingUpdateService().prepare(archiveURL: url, tracks: item.tracks, directory: directory)
        XCTAssertThrowsError(try WordTimingUpdateCommit.apply(prepared, to: item, entries: [entry]) {
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertNil(item.tracks[0].wordTimingsFilename)
        XCTAssertEqual(entry.audioStart, 0)
        XCTAssertEqual(entry.audioEnd, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path))
    }

    func testRejectsTimingUpdateForDifferentLocalAudio() async throws {
        let (item, directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("different recording".utf8).write(to: directory.appending(path: "001.wav"))
        do {
            _ = try await WordTimingUpdateService().prepare(archiveURL: url, tracks: item.tracks, directory: directory)
            XCTFail("Mismatched audio must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("different audio"))
        }
        XCTAssertNil(item.tracks[0].wordTimingsFilename)
    }

    func testBookArchiveImportsAndPersistsOptionalWordTimings() async throws {
        let (_, directory, url) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = BookImportService()
        let preview = try await service.previewArchive(url)
        XCTAssertEqual(preview.tracks[0].wordTimingsFilename, "word-timings/001.json")
        let prepared = try await service.prepare(preview, title: "Imported", orderedTracks: preview.tracks, transcriptPath: nil, externalTranscript: nil)
        let track = try XCTUnwrap(prepared.tracks.first)
        let doc = try TrackTranscriptLoader.load(track: track, directory: prepared.stagedBookDirectory)
        XCTAssertEqual(PhraseAudioTiming.range(for: (doc.text as NSString).range(of: "two"), in: doc, duration: 2), 0.6...0.9)
        await service.cancel(preview)
    }
}
