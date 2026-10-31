import XCTest
import UIKit
import SwiftUI
@testable import ForeignLanguageLearner

final class BookPaginationTests: XCTestCase {
    func testPhraseRemainsAccessibleWhenFontIsTallerThanViewport() throws {
        let source = TranscriptDocument(segments: [.init(start: 0, end: 1, text: "A complete phrase.")])
        let pages = try BookTextPagination.ranges(text: source.text, size: CGSize(width: 390, height: 90),
            scale: 1.75, category: UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
            phrases: source.ranges)
        XCTAssertEqual(pages, source.ranges)
    }
    func testTimedPhrasesNeverStraddlePagesAndFollowHasOneOwner() throws {
        let source = TranscriptDocument(segments: (0..<24).map { index in
            .init(start: Double(index), end: Double(index + 1),
                  text: "Phrase \(index): " + String(repeating: "a word in context ", count: 5))
        })
        let text = BookTextPagination.readingText(source)
        let pages = try BookTextPagination.ranges(text: text, size: CGSize(width: 390, height: 320),
            scale: 1, category: UIContentSizeCategory.large.rawValue, phrases: source.ranges)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.map { (text as NSString).substring(with: $0) }.joined(), text)
        for cue in source.ranges {
            let owner = BookTextPagination.page(containing: cue.location, ranges: pages)
            XCTAssertEqual(NSIntersectionRange(cue, pages[owner]), cue)
            XCTAssertEqual(pages.filter { NSIntersectionRange($0, cue).length > 0 }.count, 1)
        }
    }

    func testOversizedCueStaysWholeWithoutWhitespaceOnlyPages() throws {
        let source = TranscriptDocument(segments: [
            .init(start: 0, end: 1, text: String(repeating: "Long phrase with words. ", count: 80)),
            .init(start: 1, end: 2, text: String(repeating: "Another long phrase. ", count: 80)),
            .init(start: 2, end: 3, text: "Last phrase.")
        ])
        let text = BookTextPagination.readingText(source)
        let pages = try BookTextPagination.ranges(text: text, size: CGSize(width: 390, height: 240),
            scale: 1, category: UIContentSizeCategory.large.rawValue, phrases: source.ranges)
        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(pages.map { (text as NSString).substring(with: $0) }.joined(), text)
        for (index, cue) in source.ranges.enumerated() {
            XCTAssertEqual(NSIntersectionRange(cue, pages[index]), cue)
            XCTAssertFalse((text as NSString).substring(with: pages[index]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @MainActor func testPagerRetainsControllersAndDefersUpdatesDuringCancelledSwipe() throws {
        var manualStarts = 0
        var selected = -1
        let first = StableBookPager.Revision(active: 0, words: 0, index: nil, follow: 0, following: true, underline: false)
        let parent = StableBookPager(count: 4, selection: 1, revision: first,
            makePage: { _ in
                TranscriptTextView(document: .init(segments: [.init(start: nil, end: nil, text: "Page")]),
                    activeSegment: nil, following: .constant(false), followGeneration: 0,
                    onSelectionBegan: {}, handleSelection: { _, _, _, _, _ in })
            }, onManualStart: { manualStarts += 1 },
            onSelection: { selected = $0 })
        let coordinator = StableBookPager.Coordinator(parent)
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        coordinator.controller = controller
        coordinator.showInitialPage()
        let visible = try XCTUnwrap(coordinator.page(1))
        let next = try XCTUnwrap(coordinator.page(2))
        coordinator.pageViewController(controller, willTransitionTo: [next])
        coordinator.parent = StableBookPager(count: 4, selection: 1,
            revision: .init(active: 1, words: 1, index: nil, follow: 0, following: false, underline: false),
            makePage: parent.makePage, onManualStart: parent.onManualStart, onSelection: parent.onSelection)
        coordinator.update()
        XCTAssertEqual(manualStarts, 1)
        XCTAssertEqual(visible.revision, first, "Do not redraw an in-flight page")
        XCTAssertTrue(coordinator.page(2) === next)
        coordinator.pageViewController(controller, didFinishAnimating: true,
            previousViewControllers: [visible], transitionCompleted: false)
        XCTAssertEqual(selected, 1)
        XCTAssertTrue(coordinator.page(1) === visible)
        XCTAssertEqual(visible.revision.active, 1)
    }
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
                                                              height: size.height - 32))
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
