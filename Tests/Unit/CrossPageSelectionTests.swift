import XCTest
@testable import ForeignLanguageLearner

final class CrossPageSelectionTests: XCTestCase {
    func testMovingEndAcrossMultiplePagesKeepsOriginalAnchorAndAudioRange() throws {
        let document = TranscriptDocument(segments: [
            .init(start: 0, end: 2, text: "First phrase here."),
            .init(start: 2, end: 4, text: "Second phrase continues."),
            .init(start: 4, end: 6, text: "Third phrase ends.")
        ])
        let text = BookTextPagination.readingText(document)
        var selection = CrossPageSelection(range: (text as NSString).range(of: "phrase"))
        selection.beginDragging(.end)
        let third = (text as NSString).range(of: "ends")
        selection.extend(to: NSMaxRange(third), text: text, language: "en")
        XCTAssertEqual(selection.range.location, (text as NSString).range(of: "phrase").location)
        XCTAssertTrue((text as NSString).substring(with: selection.range).contains("Second phrase continues."))
        XCTAssertEqual(PhraseAudioTiming.range(for: selection.range, in: document, duration: 6), 0...6)
        selection.extend(to: document.ranges[1].location + 6, text: text, language: "en")
        XCTAssertEqual(PhraseAudioTiming.range(for: selection.range, in: document, duration: 6), 0...4)
    }

    func testMovingStartBackAcrossPagesRetainsFixedEndAndUnicodeOffsets() {
        let text = "Żółw 👨‍👩‍👧‍👦 czyta. Другая фраза. Last sentence."
        let source = text as NSString
        var selection = CrossPageSelection(range: source.range(of: "sentence"))
        let end = NSMaxRange(selection.range)
        selection.beginDragging(.start)
        selection.extend(to: 0, text: text, language: "en")
        XCTAssertEqual(selection.range.location, 0)
        XCTAssertEqual(NSMaxRange(selection.range), end)
        XCTAssertNotNil(Range(selection.range, in: text))
        XCTAssertTrue(source.substring(with: selection.range).contains("👨‍👩‍👧‍👦"))
    }

    func testDraggingPastTheOtherHandleReversesDirectionWithoutLosingAnchor() {
        let text = "one two three four five"
        let source = text as NSString
        var selection = CrossPageSelection(range: source.range(of: "three"))
        selection.beginDragging(.end)
        selection.extend(to: source.length + 100, text: text, language: "en")
        XCTAssertEqual(source.substring(with: selection.range), "three four five")
        selection.extend(to: -100, text: text, language: "en")
        XCTAssertEqual(source.substring(with: selection.range).trimmingCharacters(in: .whitespaces), "one two")
    }
}
