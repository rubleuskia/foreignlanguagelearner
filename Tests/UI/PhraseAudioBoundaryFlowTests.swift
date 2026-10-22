import XCTest

final class PhraseAudioBoundaryFlowTests: XCTestCase {
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
            XCTAssertTrue(app.buttons["audio-editor.apply"].waitForExistence(timeout: 5))
        }
        openEditor("dictionary.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("2.00"))
        app.buttons["audio-editor.apply"].tap()
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.90"))
        app.buttons["Cancel"].tap()
        openEditor("dictionary.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("2.00"))
        app.buttons["audio-editor.apply"].tap()
        app.buttons["audio-editor.save"].tap()
        openEditor("dictionary.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.90"))
        app.buttons["End"].tap()
        app.buttons["Later"].tap()
        app.buttons["audio-editor.apply"].tap()
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("3.10"))
        app.buttons["Reset to automatic boundaries"].tap()
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("2.00"))
        app.buttons["audio-editor.save"].tap()
        openEditor("dictionary.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("2.00"))
        app.buttons["Cancel"].tap()
        app.buttons["Close"].tap()
        app.buttons["dictionary.learn"].tap()
        let start = app.buttons["learn.start"]
        XCTAssertTrue(app.descendants(matching: .any)["learn.ignore-cooldown"].firstMatch.waitForExistence(timeout: 5))
        if !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        openEditor("learn.play-audio")
        app.buttons["audio-editor.apply"].tap()
        app.buttons["audio-editor.save"].tap()
        openEditor("learn.play-audio")
        XCTAssertTrue(app.staticTexts["audio-editor.range"].label.replacingOccurrences(of: ",", with: ".").contains("1.90"))
        app.buttons["Cancel"].tap()
    }
}
