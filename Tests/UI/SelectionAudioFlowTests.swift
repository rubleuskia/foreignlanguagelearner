import XCTest

final class SelectionAudioFlowTests: XCTestCase {
    @MainActor func testPlayWhileDictionaryTranslationIsLoading() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture",
                               "--slow-selection-translation-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["library.continue"].waitForExistence(timeout: 10))
        app.buttons["library.continue"].tap()
        let transcript = app.textViews["reader.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.03)).press(forDuration: 1)
        let add = app.descendants(matching: .any)["Add to Dictionary"].firstMatch
        if !add.exists { app.buttons["Forward"].tap() }
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let header = app.navigationBars["Translate in Context"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        XCTAssertTrue(app.staticTexts["Translating phrase…"].waitForExistence(timeout: 5))
        let play = app.buttons["preview.play-audio"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(play.label.hasPrefix("Pause"))
        XCTAssertTrue(app.staticTexts["Translating phrase…"].exists)
        // Translation must finish and save even when audio starts first.
        XCTAssertTrue(app.staticTexts["Кот"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.buttons["preview.add-to-dictionary"].label.contains("Added to Dictionary"))
        play.tap()
        app.buttons["Close"].tap()
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
    }
}
