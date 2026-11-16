import XCTest
import SwiftData
@testable import ForeignLanguageLearner

final class YouTubeImportTests: XCTestCase {
    func testOnlyYouTubeVideoURLsAreAccepted() {
        for url in ["https://youtu.be/jNQXAC9IVRw?t=2", "https://m.youtube.com/watch?v=jNQXAC9IVRw", "https://www.youtube.com/shorts/jNQXAC9IVRw"] {
            XCTAssertEqual(YouTubeImport.videoID(from: url), "jNQXAC9IVRw")
        }
        for url in ["https://youtube.com.evil.test/watch?v=jNQXAC9IVRw", "http://youtube.com/watch?v=jNQXAC9IVRw", "https://youtube.com/playlist?list=test", "https://youtube.com/watch?v=bad'ID"] {
            XCTAssertNil(YouTubeImport.videoID(from: url))
        }
    }

    func testRejectsBrokenTimingAndPreservesCueGaps() throws {
        var value = YouTubeImport(videoID: "jNQXAC9IVRw", title: "Sample", language: "en", duration: 19,
            cues: [.init(start: 1.2, end: 3.36, text: "First"), .init(start: 5.318, end: 7.974, text: "Second")])
        let valid = try value.validated()
        let document = TranscriptDocument(segments: valid.cues.map { .init(start: $0.start, end: $0.end, text: $0.text) })
        XCTAssertEqual(document.activeSegment(at: 2), 0)
        XCTAssertNil(document.activeSegment(at: 4))
        XCTAssertEqual(document.activeSegment(at: 6), 1)
        value.cues[1].end = 40
        XCTAssertThrowsError(try value.validated())
        value.cues[1].end = 7.974
        value.cues[1].start = -1
        XCTAssertThrowsError(try value.validated())
        value.cues[1].start = 5
        value.duration = .nan
        XCTAssertThrowsError(try value.validated())
    }

    func testThumbnailFallbackProducesLocalJPEGAndRemovesDownloads() async throws {
        let downloads = ThumbnailDownloads(firstStatus: 404)
        let data = await YouTubeCoverService.fetch(videoID: "lmaZWix9h6M") { try await downloads.download($0) }
        let cover = try XCTUnwrap(data)
        XCTAssertEqual(Array(cover.prefix(2)), [0xff, 0xd8])
        let urls = await downloads.requests
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://i.ytimg.com/vi/lmaZWix9h6M/maxresdefault.jpg",
            "https://i.ytimg.com/vi/lmaZWix9h6M/hqdefault.jpg"
        ])
        let files = await downloads.temporaryFiles
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testUnavailableAndInvalidThumbnailsAreOptional() async throws {
        let downloads = ThumbnailDownloads(firstStatus: 200, validImage: false)
        let cover = await YouTubeCoverService.fetch(videoID: "lmaZWix9h6M") { try await downloads.download($0) }
        XCTAssertNil(cover)
        let urls = await downloads.requests
        XCTAssertEqual(urls.count, 2)
        let files = await downloads.temporaryFiles
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let offline = await YouTubeCoverService.fetch(videoID: "lmaZWix9h6M") { _ in
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertNil(offline)
    }

    @MainActor func testSubtitleReplacementKeepsIdentityPositionCoverAndDictionaryLanguage() throws {
        let container = try ModelContainer(for: LearningItem.self, DictionaryEntry.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let item = LearningItem(id: UUID(), title: "Video", mediaKind: "youtube", mediaFilename: "",
                                transcriptFilename: "", duration: 100,
                                segments: [.init(start: 0, end: 10, text: "English")], sourceLanguageCode: "en")
        item.youtubeVideoID = "lmaZWix9h6M"
        item.lastPosition = 45
        item.coverFilename = "cover.jpg"
        item.readingCharacterOffset = 20
        item.isBookCompleted = true
        context.insert(item)
        let entry = DictionaryEntry(text: "English", item: item, segmentIndex: 0)
        context.insert(entry)
        try context.save()
        XCTAssertTrue(item.isYouTube)
        XCTAssertEqual(item.youtubeURL?.absoluteString, "https://www.youtube.com/watch?v=lmaZWix9h6M")
        let value = YouTubeImport(videoID: "lmaZWix9h6M", title: "Video", language: "pl", duration: 100,
                                  cues: [.init(start: 0, end: 10, text: "Polski")])
        try YouTubeTranscriptUpdateService.replace(value, language: "pl", item: item, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LearningItem>()), 1)
        XCTAssertEqual(item.segments.first?.text, "Polski")
        XCTAssertEqual(item.sourceLanguageCode, "pl")
        XCTAssertEqual(item.lastPosition, 45)
        XCTAssertEqual(item.coverFilename, "cover.jpg")
        XCTAssertEqual(item.readingCharacterOffset, 0)
        XCTAssertFalse(item.isBookCompleted)
        XCTAssertFalse(item.resourceRevision.isEmpty)
        XCTAssertNil(entry.segmentIndex)
        XCTAssertEqual(entry.sourceLanguageCode, "en")
        var otherVideo = value
        otherVideo.videoID = "jNQXAC9IVRw"
        XCTAssertThrowsError(try YouTubeTranscriptUpdateService.replace(otherVideo, language: "pl", item: item, context: context))
        let revision = item.resourceRevision
        var replacement = value
        replacement.language = "en"
        replacement.cues[0].text = "Changed"
        replacement.language = "en"
        XCTAssertThrowsError(try YouTubeTranscriptUpdateService.replace(replacement, language: "en", item: item,
            context: context, save: { throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(item.segments.first?.text, "Polski")
        XCTAssertEqual(item.sourceLanguageCode, "pl")
        XCTAssertEqual(item.resourceRevision, revision)
        XCTAssertEqual(item.lastPosition, 45)
        XCTAssertThrowsError(try YouTubeTranscriptUpdateService.replace(value, language: "pl", item: item,
            expectedRevision: "stale", context: context))
        XCTAssertThrowsError(try YouTubeTranscriptUpdateService.replace(value, language: "en", item: item, context: context))
    }

    @MainActor func testPlaybackKeepsSavedPositionUntilPlayerReportsProgress() {
        let playback = YouTubePlayback(initialPosition: 123.5)
        XCTAssertEqual(playback.position, 123.5)
        XCTAssertFalse(playback.hasReceivedPosition)
        XCTAssertEqual(YouTubePlayback(initialPosition: .nan).position, 0)
    }
}

private actor ThumbnailDownloads {
    let firstStatus: Int
    let validImage: Bool
    var requests: [URL] = []
    var temporaryFiles: [URL] = []

    init(firstStatus: Int, validImage: Bool = true) {
        self.firstStatus = firstStatus
        self.validImage = validImage
    }

    func download(_ request: URLRequest) throws -> (URL, URLResponse) {
        let url = try XCTUnwrap(request.url)
        requests.append(url)
        let temporaryURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        temporaryFiles.append(temporaryURL)
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try (validImage ? image : Data("invalid image".utf8)).write(to: temporaryURL)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: requests.count == 1 ? firstStatus : 200,
                                                   httpVersion: nil, headerFields: nil))
        return (temporaryURL, response)
    }
}
