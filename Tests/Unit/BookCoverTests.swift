import AVFoundation
import ImageIO
import SwiftData
import UIKit
import XCTest
import ZIPFoundation
@testable import ForeignLanguageLearner

final class BookCoverTests: XCTestCase {
    @MainActor private func cover() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 1400))
        return try XCTUnwrap(renderer.jpegData(withCompressionQuality: 1) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1800, height: 1400))
        })
    }

    func testCoverNameMatchingSupportsNestedImagesWithoutMatchingUnrelatedFiles() {
        for path in ["cover.jpg", "images/COVER.PNG", "cover.heic", "Cover.JPEG", "art/cover.webp"] {
            XCTAssertTrue(BookCoverService.isCoverPath(path), path)
        }
        for path in ["cover.txt", "my-cover.jpg", "cover/photo.jpg", "cover.jpg.exe", "cover"] {
            XCTAssertFalse(BookCoverService.isCoverPath(path), path)
        }
    }

    @MainActor func testCoverDownsamplingAndBundledAssets() throws {
        let jpeg = try BookCoverService.jpeg(cover())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1200)
        XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int), 1200)
        XCTAssertThrowsError(try BookCoverService.jpeg(Data("not an image".utf8)))
        XCTAssertThrowsError(try BookCoverService.jpeg(Data(repeating: 0, count: BookCoverService.maximumBytes + 1)))
        var size = 0
        for name in BookCoverService.bundled {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "jpg"))
            let data = try Data(contentsOf: url)
            XCTAssertNotNil(UIImage(data: data))
            size += data.count
        }
        XCTAssertLessThan(size, 1_500_000)
    }

    @MainActor func testRawAndStrictPackagesDetectCoverAndKeepItAcrossReviewRetries() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = directory.appending(path: "photo.jpg")
        try cover().write(to: photo)
        let invalid = directory.appending(path: "invalid.jpg")
        try Data("invalid nested cover must lose to valid root cover".utf8).write(to: invalid)
        let text = directory.appending(path: "book.txt")
        try Data("A small story.".utf8).write(to: text)
        let audio = directory.appending(path: "chapter.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
        buffer.frameLength = 8000
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        for strict in [false, true] {
            let zip = directory.appending(path: strict ? "strict.zip" : "raw.zip")
            let archive = try Archive(url: zip, accessMode: .create)
            try archive.addEntry(with: "chapter.wav", fileURL: audio)
            try archive.addEntry(with: "book.txt", fileURL: text)
            try archive.addEntry(with: "images/COVER.JPG", fileURL: strict ? invalid : photo)
            if strict { try archive.addEntry(with: "cover.PNG", fileURL: photo) }
            if strict {
                let manifest = BookManifest(format: BookManifest.formatIdentifier, schemaVersion: 1, title: "Story", sourceLanguage: "en",
                    transcript: "book.txt", tracks: [.init(id: "one", title: "One", audio: "chapter.wav", alignmentStatus: .untimed, subtitle: nil, textRange: nil)], textMapping: nil)
                let url = directory.appending(path: "manifest.json")
                try JSONEncoder().encode(manifest).write(to: url)
                try archive.addEntry(with: "manifest.json", fileURL: url)
            }
            let service = BookImportService()
            let preview = try await service.previewArchive(zip)
            XCTAssertEqual(preview.coverFilename, "cover.jpg")
            XCTAssertEqual(preview.ignoredFileCount, 0)
            let builtin = try await service.prepare(preview, title: "Story", orderedTracks: preview.tracks,
                transcriptPath: preview.selectedTranscript, externalTranscript: nil, useArchiveCover: false)
            XCTAssertNil(builtin.coverFilename)
            let restored = try await service.prepare(preview, title: "Story", orderedTracks: preview.tracks,
                transcriptPath: preview.selectedTranscript, externalTranscript: nil)
            XCTAssertEqual(restored.coverFilename, "cover.jpg")
            XCTAssertNotNil(UIImage(contentsOfFile: restored.stagedBookDirectory.appending(path: "cover.jpg").path))
            let custom = try await service.prepare(preview, title: "Story", orderedTracks: preview.tracks,
                transcriptPath: preview.selectedTranscript, externalTranscript: nil, coverData: cover(), useArchiveCover: false)
            XCTAssertEqual(custom.coverFilename, "cover.jpg")
            await service.cancel(preview)
            XCTAssertFalse(FileManager.default.fileExists(atPath: custom.stagedBookDirectory.path))
        }
    }

    @MainActor func testChapterPresentationKeepsSavedPositionsSeparateFromCompletion() {
        let item = LearningItem(id: UUID(), title: "Book", mediaKind: "audio", mediaFilename: "", transcriptFilename: "", duration: 100, segments: [], tracks: [
            .init(id: "one", title: "One", mediaFilename: "1.wav", duration: 40, lastPosition: 20),
            .init(id: "two", title: "Two", mediaFilename: "2.wav", duration: 60, lastPosition: 0, isCompleted: true)
        ], lastTrackID: "one")
        let chapters = BookChapterPresentation.chapters(item)
        XCTAssertEqual(chapters[0].progress, 0.5)
        XCTAssertTrue(chapters[0].current)
        XCTAssertFalse(chapters[0].completed)
        XCTAssertEqual(chapters[1].progress, 1)
        XCTAssertEqual(item.lastTrackID, "one")
        XCTAssertEqual(item.tracks[0].lastPosition, 20)
        XCTAssertEqual(item.coverFilename, "")
        XCTAssertEqual(item.bundledCoverName, "cover-books")
        item.tracks = []
        item.parts = [.init(start: 40, end: 100, lastPosition: 55)]
        item.lastPosition = 55
        XCTAssertEqual(BookChapterPresentation.chapters(item)[0].position, 15)
        XCTAssertEqual(BookChapterPresentation.chapters(item)[0].progress, 0.25)
    }
}
