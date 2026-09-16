import XCTest

final class LibraryFlowTests: XCTestCase {
    @MainActor
    func testEmptyLibraryImportAndDictionary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 10))
        app.buttons["library.upload"].tap()
        XCTAssertTrue(app.buttons["Choose audio or video"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose transcript"].exists)
        XCTAssertTrue(app.buttons["import.media"].exists)
        XCTAssertTrue(app.buttons["import.transcript"].exists)
        XCTAssertFalse(app.buttons["Import"].isEnabled)
        app.buttons["Cancel"].tap()
        app.buttons["Dictionary"].tap()
        XCTAssertTrue(app.staticTexts["No saved phrases"].waitForExistence(timeout: 5))
    }
}
