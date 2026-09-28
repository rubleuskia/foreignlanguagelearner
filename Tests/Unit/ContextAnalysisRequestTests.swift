import XCTest
@testable import ForeignLanguageLearner

final class ContextAnalysisRequestTests: XCTestCase {
    private let subject = ContextAnalysisSubject.dictionaryEntry(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    func testBuildSelectsSecondRepeatedOccurrenceByExactUTF16Range() throws {
        let text = "Zamek i zamek."
        let request = try build(text: text, expected: "zamek", range: NSRange(location: 8, length: 5))

        XCTAssertEqual(request.selectedText, "zamek")
        XCTAssertEqual(request.contextFragment, text)
        XCTAssertEqual(request.selectionLocationUTF16, 8)
        XCTAssertFalse(request.contextWasReduced)
    }

    func testGoldenSelectionOffsetsDescribeExpectedOccurrences() throws {
        let jacket = try build(text: "Zepsuł się zamek w kurtce.", expected: "zamek",
                               range: NSRange(location: 11, length: 5))
        let castle = try build(text: "Ten zamek stoi na wzgórzu.", expected: "zamek",
                               range: NSRange(location: 4, length: 5))

        XCTAssertEqual(jacket.selectedText, "zamek")
        XCTAssertEqual(castle.selectedText, "zamek")
    }

    func testRejectsMissingNegativeNotFoundAndOverflowingRanges() {
        XCTAssertThrowsError(try build(context: nil, expected: "a")) { XCTAssertEqual($0 as? ContextAnalysisError, .invalidContext) }
        assertInvalid(text: "abc", expected: "a", range: NSRange(location: -1, length: 1))
        assertInvalid(text: "abc", expected: "a", range: NSRange(location: NSNotFound, length: 1))
        assertInvalid(text: "abc", expected: "a", range: NSRange(location: 2, length: 2))
        assertInvalid(text: "abc", expected: "a", range: NSRange(location: Int.max - 1, length: 4))
        assertInvalid(text: "abc", expected: "", range: NSRange(location: 0, length: 0))
    }

    func testRejectsRangesInsideSurrogateCombiningAndZWJGraphemes() {
        assertInvalid(text: "A😀B", expected: "😀", range: NSRange(location: 1, length: 1))
        assertInvalid(text: "Ae\u{301}B", expected: "e", range: NSRange(location: 1, length: 1))
        let family = "👨‍👩‍👧‍👦"
        assertInvalid(text: "A\(family)B", expected: family, range: NSRange(location: 1, length: 2))
    }

    func testAcceptsWholeComposedCharacterAndPreservesExactWhitespace() throws {
        let selected = "e\u{301}"
        let text = "  A \(selected)  B\nC  "
        let range = (text as NSString).range(of: selected)
        let request = try build(text: text, expected: selected, range: range)

        XCTAssertEqual(request.contextFragment, text)
        XCTAssertEqual(request.selectedText, selected)
        XCTAssertEqual((request.contextFragment as NSString).substring(
            with: NSRange(location: request.selectionLocationUTF16, length: request.selectionLengthUTF16)
        ), selected)
    }

    func testNormalizationAllowsWhitespaceOnlyDifferencesButNotCaseOrDiacriticFolding() throws {
        XCTAssertNoThrow(try build(text: "dzień   dobry", expected: "dzień dobry",
                                   range: NSRange(location: 0, length: 13)))
        assertInvalid(text: "Żółć", expected: "żółć", range: NSRange(location: 0, length: 4))
        assertInvalid(text: "zółć", expected: "żółć", range: NSRange(location: 0, length: 4))
    }

    func testPreservesNewlinesAbbreviationsAndMultipleSentences() throws {
        let text = "Dr Kowalski wyszedł.\nPotem wrócił! Czy został?"
        let range = (text as NSString).range(of: "wrócił")
        let request = try build(text: text, expected: "wrócił", range: range)

        XCTAssertEqual(request.contextFragment, text)
        XCTAssertEqual(request.selectionLocationUTF16, range.location)
    }

    func testSelectionBoundaryAllows256AndRejects257UTF16Units() throws {
        let allowed = String(repeating: "a", count: 256)
        XCTAssertNoThrow(try build(text: allowed, expected: allowed,
                                   range: NSRange(location: 0, length: 256)))
        let rejected = String(repeating: "a", count: 257)
        XCTAssertThrowsError(try build(text: rejected, expected: rejected,
                                       range: NSRange(location: 0, length: 257))) {
            XCTAssertEqual($0 as? ContextAnalysisError, .inputTooLarge)
        }
    }

    func testContextBoundaryKeeps1400AndReduces1401AroundSelection() throws {
        let exact = String(repeating: "a", count: 697) + "zamek" + String(repeating: "b", count: 698)
        let exactRequest = try build(text: exact, expected: "zamek", range: NSRange(location: 697, length: 5))
        XCTAssertEqual(exactRequest.contextFragment.utf16.count, 1_400)
        XCTAssertFalse(exactRequest.contextWasReduced)

        let long = String(repeating: "a", count: 698) + "zamek" + String(repeating: "b", count: 698)
        let reduced = try build(text: long, expected: "zamek", range: NSRange(location: 698, length: 5))
        XCTAssertEqual(reduced.contextFragment.utf16.count, 1_400)
        XCTAssertEqual(reduced.selectionLocationUTF16, 697)
        XCTAssertTrue(reduced.contextWasReduced)
        XCTAssertEqual((reduced.contextFragment as NSString).substring(
            with: NSRange(location: reduced.selectionLocationUTF16, length: reduced.selectionLengthUTF16)
        ), "zamek")
    }

    func testShortSideTransfersUnusedBudgetToOtherSide() throws {
        let text = "x" + "zamek" + String(repeating: "b", count: 2_000)
        let request = try build(text: text, expected: "zamek", range: NSRange(location: 1, length: 5))

        XCTAssertEqual(request.contextFragment.first, "x")
        XCTAssertEqual(request.selectionLocationUTF16, 1)
        XCTAssertEqual(request.contextFragment.utf16.count, 1_400)
    }

    func testReductionRoundsInwardAtCharacterBoundaries() throws {
        let cluster = "👨‍👩‍👧‍👦"
        let text = String(repeating: cluster, count: 100) + "zamek" + String(repeating: cluster, count: 100)
        let range = (text as NSString).range(of: "zamek")
        let request = try build(text: text, expected: "zamek", range: range)

        XCTAssertLessThanOrEqual(request.contextFragment.utf16.count, 1_400)
        XCTAssertEqual((request.contextFragment as NSString).substring(
            with: NSRange(location: request.selectionLocationUTF16, length: request.selectionLengthUTF16)
        ), "zamek")
        XCTAssertNotNil(Range(NSRange(location: request.selectionLocationUTF16,
                                      length: request.selectionLengthUTF16), in: request.contextFragment))
    }

    func testExplicitRetryReductionUses700AndPreservesIdentity() throws {
        let text = String(repeating: "a", count: 700) + "zamek" + String(repeating: "b", count: 700)
        let request = try build(text: text, expected: "zamek", range: NSRange(location: 700, length: 5))
        let reduced = try ContextAnalysisRequestBuilder.reducing(request)

        XCTAssertLessThanOrEqual(reduced.contextFragment.utf16.count, 700)
        XCTAssertEqual(reduced.requestID, request.requestID)
        XCTAssertEqual(reduced.subject, request.subject)
        XCTAssertEqual(reduced.revision, request.revision)
        XCTAssertTrue(reduced.contextWasReduced)
        XCTAssertEqual((reduced.contextFragment as NSString).substring(
            with: NSRange(location: reduced.selectionLocationUTF16, length: reduced.selectionLengthUTF16)
        ), "zamek")
    }

    func testRejectsEmptyLanguageCodes() {
        XCTAssertThrowsError(try build(text: "zamek", expected: "zamek",
                                       range: NSRange(location: 0, length: 5), sourceLanguage: "")) {
            XCTAssertEqual($0 as? ContextAnalysisError, .invalidLanguage)
        }
    }

    private func build(text: String, expected: String, range: NSRange,
                       sourceLanguage: String = "pl") throws -> ContextAnalysisRequest {
        try build(context: SelectionContext(text: text, selection: range), expected: expected,
                  sourceLanguage: sourceLanguage)
    }

    private func build(context: SelectionContext?, expected: String,
                       sourceLanguage: String = "pl") throws -> ContextAnalysisRequest {
        try ContextAnalysisRequestBuilder.build(.init(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            subject: subject,
            revision: 7,
            expectedSelectedText: expected,
            context: context,
            sourceLanguage: sourceLanguage,
            targetLanguage: "ru",
            promptVersion: "context-analysis-v2"
        ))
    }

    private func assertInvalid(text: String, expected: String, range: NSRange,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try build(text: text, expected: expected, range: range), file: file, line: line) {
            XCTAssertEqual($0 as? ContextAnalysisError, .invalidContext, file: file, line: line)
        }
    }
}
