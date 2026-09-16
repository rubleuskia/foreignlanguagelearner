import XCTest

final class LibraryFlowTests: XCTestCase {
    @MainActor
    func testBothFilePickersPresentDocumentBrowser() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        // Opening media first catches the competing-fileImporter regression.
        for identifier in ["import.media", "import.transcript"] {
            app.launch()
            app.buttons["library.upload"].tap()
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 5),
                          "The document picker should open for \(identifier)")
            app.terminate()
        }
    }

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
        XCTAssertFalse(app.buttons["Import"].isEnabled)
        app.buttons["Cancel"].tap()
        app.buttons["Dictionary"].tap()
        XCTAssertTrue(app.staticTexts["No saved phrases"].waitForExistence(timeout: 5))
    }
}
