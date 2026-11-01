import XCTest

final class SelectionAudioFlowTests: XCTestCase {
    @MainActor func testSelectionHandleTurnsPageAndSendsWholePhraseToDictionary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--phrase-pages-fixture",
                               "--slow-selection-translation-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["library.continue"].waitForExistence(timeout: 10))
        app.buttons["library.continue"].tap()
        let text = app.textViews["reader.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.06)).press(forDuration: 0.7)
        let end = app.descendants(matching: .any)["reader.selection.end"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        let number = app.staticTexts["reader.page-number"]
        let first = number.label
        let edge = text.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.45))
        end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: edge, withVelocity: .slow, thenHoldForDuration: 1.25)
        XCTAssertNotEqual(number.label, first, "Dragging a selection handle to the edge must turn the page")
        let next = number.label
        let start = app.descendants(matching: .any)["reader.selection.start"].firstMatch
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: text.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.35)),
                   withVelocity: .slow, thenHoldForDuration: 1.25)
        XCTAssertNotEqual(number.label, next, "The start handle must also cross back to the previous page")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Selection retained across page boundaries"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let add = app.descendants(matching: .any)["Add to Dictionary"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["Translate in Context"].waitForExistence(timeout: 5))
        let header = app.navigationBars["Translate in Context"]
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        let original = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Kot i pies czytają książkę")).firstMatch
        XCTAssertTrue(original.exists, "The full selected source must reach the dictionary preview")
        XCTAssertGreaterThan(original.label.count, 100)
        for _ in 0..<8 where !app.buttons["preview.play-audio"].exists { app.swipeUp() }
        XCTAssertTrue(app.buttons["preview.play-audio"].exists)
    }

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
