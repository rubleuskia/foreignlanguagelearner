import XCTest

final class WordAudioTimingFlowTests: XCTestCase {
    @MainActor func testExistingBookOffersPhraseAudioUpdatePicker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture"]
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10))
        story.tap()
        let update = app.buttons["reader.update-phrase-audio"]
        XCTAssertTrue(update.waitForExistence(timeout: 10))
        XCTAssertTrue(update.isHittable)
        update.tap()
        XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 20))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Update phrase audio — book archive picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
