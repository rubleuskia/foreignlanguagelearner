import XCTest
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
}
