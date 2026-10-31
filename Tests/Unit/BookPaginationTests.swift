import XCTest
import UIKit
@testable import ForeignLanguageLearner

final class BookPaginationTests: XCTestCase {
    func testSubtitleReflowPreservesOffsetsAndAudioSelectionAcrossCues() {
        let source = TranscriptDocument(segments: [
            .init(start: 0, end: 2, text: "Hello\nworld 🌍"),
            .init(start: 2, end: 4, text: "Next phrase.")
        ], sourceIndices: [7, 8])
        let text = BookTextPagination.readingText(source)
        XCTAssertFalse(text.contains("\n"))
        XCTAssertEqual((text as NSString).length, (source.text as NSString).length)
        let range = NSRange(location: 6, length: (text as NSString).length - 6)
        let page = TranscriptDocument(pageOf: source, text: text, range: range)
        XCTAssertEqual(page.sourceIndices, [7, 8])
        XCTAssertEqual(page.ranges[1].location + range.location, source.ranges[1].location)
        XCTAssertEqual(PhraseAudioTiming.range(for: range, in: source, duration: 4), 0...4)
    }

    func testUntimedBookRetainsParagraphs() {
        let source = TranscriptDocument(segments: [.init(start: nil, end: nil, text: "First paragraph.\n\nSecond paragraph.")])
        XCTAssertEqual(BookTextPagination.readingText(source), source.text)
    }

    func testPagesCoverUnicodeTextWithoutGapsAndFitTheViewport() throws {
        let text = String(repeating: "A story about żółw, café and a family 👨‍👩‍👧‍👦. ", count: 180)
        for size in [CGSize(width: 390, height: 480), CGSize(width: 740, height: 200)] {
            let ranges = try BookTextPagination.ranges(text: text, size: size, scale: 1.25,
                                                       category: UIContentSizeCategory.large.rawValue)
            XCTAssertGreaterThan(ranges.count, 1)
            XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }.joined(), text)
            let traits = UITraitCollection(preferredContentSizeCategory: .large)
            for (index, range) in ranges.enumerated() {
                XCTAssertNotNil(Range(range, in: text))
                XCTAssertEqual(BookTextPagination.page(containing: range.location, ranges: ranges), index)
                let storage = NSTextStorage(string: (text as NSString).substring(with: range), attributes: [
                    .font: ReadingTypography.font(compatibleWith: traits, scale: 1.25),
                    .paragraphStyle: ReadingTypography.paragraph(compatibleWith: traits)
                ])
                let manager = NSLayoutManager()
                let container = NSTextContainer(size: CGSize(width: size.width - max(24, (size.width - 680) / 2) * 2,
                                                              height: size.height - 72))
                storage.addLayoutManager(manager)
                manager.addTextContainer(container)
                manager.ensureLayout(for: container)
                let visible = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
                XCTAssertEqual(visible.length, range.length, "Page \(index) clips its final characters")
            }
        }
    }

    func testLargerFontRepaginatesAroundTheSameReadingOffset() throws {
        let text = String(repeating: "Words in a book continue across page boundaries. ", count: 100)
        let size = CGSize(width: 390, height: 500)
        let small = try BookTextPagination.ranges(text: text, size: size, scale: 0.75, category: UIContentSizeCategory.large.rawValue)
        let large = try BookTextPagination.ranges(text: text, size: size, scale: 1.75, category: UIContentSizeCategory.large.rawValue)
        XCTAssertGreaterThan(large.count, small.count)
        let offset = small[2].location
        XCTAssertTrue(NSLocationInRange(offset, large[BookTextPagination.page(containing: offset, ranges: large)]))
    }
}
