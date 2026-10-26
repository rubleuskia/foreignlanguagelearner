import XCTest

final class WordExplanationFlowTests: XCTestCase {
    @MainActor
    func testInlineExplanationExpandsAndCollapsesWithoutLosingTranslation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture", "--learning-context-fixture",
                               "--word-explanation-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.learn"].tap()
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-learn"].tap()
        XCTAssertFalse(app.buttons["word-explanation.toggle.0"].exists)
        app.buttons["learn.check"].tap()
        let word = app.buttons["word-explanation.toggle.0"]
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        if !word.isHittable { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["Простыми словами"].exists)
        word.tap()
        XCTAssertTrue(app.staticTexts["Простыми словами"].waitForExistence(timeout: 5))
        if !app.staticTexts["Типовые фразы"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Типовые фразы"].exists)
        XCTAssertTrue(app.staticTexts["miłego dnia"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Inline word explanation"
        attachment.lifetime = .keepAlways
        add(attachment)
        if !word.isHittable { app.swipeDown() }
        word.tap()
        XCTAssertFalse(app.staticTexts["Простыми словами"].exists)
        word.tap()
        XCTAssertTrue(app.staticTexts["Простыми словами"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["learn.translation"].label, "добрый день")
    }
}
