import XCTest
@testable import ForeignLanguageLearner

final class PracticeSessionTests: XCTestCase {
    func testTranslationStartsHiddenAndCanBeRevealed() {
        var session = PracticeSession(word: "Cześć", translation: "Hello")
        XCTAssertFalse(session.isTranslationVisible)
        session.revealTranslation()
        XCTAssertTrue(session.isTranslationVisible)
        XCTAssertEqual(session.translation, "Hello")
    }

    func testRestartHidesTranslationAndPreservesCard() {
        var session = PracticeSession.sample
        session.revealTranslation()
        session.restart()
        XCTAssertFalse(session.isTranslationVisible)
        XCTAssertEqual(session.word, "Cześć")
    }
}
