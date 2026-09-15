import XCTest

final class PracticeFlowTests: XCTestCase {
    @MainActor
    func testRevealAndRestart() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["practice.word"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["practice.translation"].exists)
        app.buttons["practice.reveal"].tap()
        XCTAssertTrue(app.staticTexts["practice.translation"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["practice.translation"].label, "Hello")
        app.buttons["practice.restart"].tap()
        XCTAssertTrue(app.buttons["practice.reveal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["practice.translation"].exists)
    }
}
