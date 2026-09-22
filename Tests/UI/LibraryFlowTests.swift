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
            XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 20),
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
        XCTAssertTrue(app.descendants(matching: .any)["import.language"].exists)
        XCTAssertTrue(app.switches["import.split"].exists)
        XCTAssertFalse(app.buttons["Import"].isEnabled)
        app.buttons["Cancel"].tap()
        app.buttons["Dictionary"].tap()
        XCTAssertTrue(app.staticTexts["No saved phrases"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLearningRoundHidesAnswerThenShowsGlobalLearntList() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()

        app.buttons["Dictionary"].tap()
        let learn = app.buttons["dictionary.learn"]
        XCTAssertTrue(learn.waitForExistence(timeout: 5))
        learn.tap()
        let start = app.buttons["learn.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        XCTAssertTrue(app.staticTexts["learn.translation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["learn.original"].exists,
                       "The original must stay hidden before Check")
        app.buttons["learn.check"].tap()
        XCTAssertTrue(app.staticTexts["learn.original"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Audio unavailable on this device"].exists)
        app.buttons["learn.right"].tap()

        XCTAssertTrue(app.staticTexts["Round complete"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All learnt phrases"].exists)
        let learntOriginals = app.staticTexts.matching(identifier: "learn.completion.original")
        XCTAssertEqual(learntOriginals.count, 1,
                       "Only valid global level-4 entries belong in the completion list")
        XCTAssertEqual(learntOriginals.firstMatch.label, "do widzenia",
                       "The global list includes entries learned before this round")
    }
}
