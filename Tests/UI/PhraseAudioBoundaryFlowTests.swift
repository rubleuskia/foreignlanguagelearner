import XCTest

final class PhraseAudioBoundaryFlowTests: XCTestCase {
    @MainActor func testTimelineHandlesChangeBothBoundariesAndSave() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--audio-boundary-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.entry.Kot"].tap()
        app.buttons["dictionary.play-audio"].press(forDuration: 1)
        app.buttons["Edit audio boundaries"].tap()
        let start = app.descendants(matching: .any)["audio-editor.start-slider"].firstMatch
        let end = app.descendants(matching: .any)["audio-editor.end-slider"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let range = app.staticTexts["audio-editor.range"]
        let initial = range.label
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: start.coordinate(withNormalizedOffset: CGVector(dx: 2, dy: 0.5)))
        XCTAssertNotEqual(range.label, initial)
        let afterStart = range.label
        end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 2, dy: 0.5)))
        XCTAssertNotEqual(range.label, afterStart)
        let saved = range.label
        app.buttons["audio-editor.save"].tap()
        app.buttons["dictionary.play-audio"].press(forDuration: 1)
        app.buttons["Edit audio boundaries"].tap()
        XCTAssertEqual(app.staticTexts["audio-editor.range"].label, saved)
    }

    @MainActor func testNewEntryAudioModesEditIndependently() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--audio-boundary-fixture", "--dual-audio-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.entry.Kot"].tap()
        XCTAssertTrue(app.buttons["Whole phrase"].waitForExistence(timeout: 5))
        app.buttons["Whole phrase"].tap()
        app.buttons["dictionary.play-audio"].press(forDuration: 1)
        app.buttons["Edit audio boundaries"].tap()
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("0.50"))
        if !app.buttons["audio-editor.apply"].exists { app.buttons["Move boundary"].tap() }
        app.buttons["audio-editor.apply"].tap()
        app.buttons["audio-editor.save"].tap()
        app.buttons["Selected word"].tap()
        app.buttons["dictionary.play-audio"].press(forDuration: 1)
        app.buttons["Edit audio boundaries"].tap()
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.50"))
        app.buttons["Cancel"].tap()
        app.buttons["Whole phrase"].tap()
        app.buttons["dictionary.play-audio"].press(forDuration: 1)
        app.buttons["Edit audio boundaries"].tap()
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("0.40"))
    }

    @MainActor func testEditCancelSaveResetAndLearningMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--audio-boundary-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.entry.Kot"].tap()
        func openEditor(_ identifier: String) {
            let play = app.buttons[identifier]
            XCTAssertTrue(play.waitForExistence(timeout: 5))
            play.press(forDuration: 1)
            app.buttons["Edit audio boundaries"].tap()
            app.buttons["Move boundary"].tap()
            XCTAssertTrue(app.buttons["audio-editor.apply"].waitForExistence(timeout: 5))
        }
        openEditor("dictionary.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.50"))
        if !app.buttons["audio-editor.apply"].exists { app.buttons["Move boundary"].tap() }
        app.buttons["audio-editor.apply"].tap()
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.40"))
        app.buttons["Cancel"].tap()
        openEditor("dictionary.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.50"))
        if !app.buttons["audio-editor.apply"].exists { app.buttons["Move boundary"].tap() }
        app.buttons["audio-editor.apply"].tap()
        app.buttons["audio-editor.save"].tap()
        openEditor("dictionary.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.40"))
        app.buttons["End"].tap()
        app.buttons["Later"].tap()
        if !app.buttons["audio-editor.apply"].exists { app.buttons["Move boundary"].tap() }
        app.buttons["audio-editor.apply"].tap()
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("3.60"))
        app.buttons["Move boundary"].tap()
        app.buttons["Reset to automatic boundaries"].tap()
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.50"))
        app.buttons["audio-editor.save"].tap()
        openEditor("dictionary.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.50"))
        app.buttons["Cancel"].tap()
        app.buttons["Close"].tap()
        app.buttons["dictionary.learn"].tap()
        let start = app.buttons["learn.start"]
        XCTAssertTrue(app.descendants(matching: .any)["learn.ignore-cooldown"].firstMatch.waitForExistence(timeout: 5))
        if !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        openEditor("learn.play-audio")
        if !app.buttons["audio-editor.apply"].exists { app.buttons["Move boundary"].tap() }
        app.buttons["audio-editor.apply"].tap()
        app.buttons["audio-editor.save"].tap()
        openEditor("learn.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.40"))
        app.buttons["Cancel"].tap()
    }
}
