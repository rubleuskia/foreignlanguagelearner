import XCTest

final class OnboardingFlowTests: XCTestCase {
    @MainActor func testLargeTextTipKeepsDismissActionReachableByScrolling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--progressive-books-fixture", "--onboarding-fixture",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let book = app.staticTexts["Text example"].firstMatch
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 10))
        for _ in 0..<8 where !book.exists || !book.isHittable { app.swipeUp() }
        XCTAssertTrue(book.exists)
        book.tap()
        app.buttons["book.continue"].tap()
        let dismiss = app.buttons["onboarding.got-it"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 10))
        let tip = app.scrollViews.containing(.button, identifier: "onboarding.got-it").firstMatch
        XCTAssertTrue(tip.exists)
        for _ in 0..<6 where !dismiss.isHittable { tip.swipeUp() }
        XCTAssertTrue(dismiss.isHittable)
        capture(app, name: "Accessible reading tip")
        dismiss.tap()
        XCTAssertTrue(app.textViews["reader.transcript"].exists)
    }

    @MainActor func testExampleOpensReaderWithoutCloudSetup() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["library.example"].tap()
        XCTAssertTrue(app.textViews["reader.transcript"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.secureTextFields["OpenAI API key"].exists)
        capture(app, name: "Example reading")
    }

    @MainActor func testWizardExplainsFourInputsAndKeepsCommitUnavailableWithoutFiles() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["library.upload"].tap()
        for title in ["Book text", "Audio file", "Audio ZIP + separate text", "Complete book ZIP"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists)
        }
        capture(app, name: "Import choices")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Book text")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Choose TXT"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["import.check"].isEnabled)
        XCTAssertFalse(app.buttons["import.commit"].exists)
    }

    @MainActor func testTextOnlyReaderHasNoPlayerAndCanAddAudio() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--progressive-books-fixture"]
        app.launch()
        app.staticTexts["Text example"].firstMatch.tap()
        app.buttons["book.continue"].tap()
        XCTAssertTrue(app.textViews["reader.transcript"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.sliders["Playback position"].exists)
        capture(app, name: "Text-only reading")
        app.buttons["book.resources"].tap()
        app.buttons["Add audio"].tap()
        XCTAssertTrue(app.buttons["Choose audio"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["import.check"].isEnabled)
    }

    @MainActor func testAudioOnlyAndUntimedCombinedBooksOpenUsefulScreens() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--progressive-books-fixture"]
        app.launch()
        app.staticTexts["Audio example"].firstMatch.tap()
        app.buttons["book.continue"].tap()
        XCTAssertTrue(app.staticTexts["Listen to your book"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sliders["Track playback position"].exists)
        capture(app, name: "Audio-only listening")
        app.buttons["book.resources"].tap()
        app.buttons["Add text"].tap()
        XCTAssertTrue(app.buttons["Choose TXT"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.staticTexts["Combined example"].firstMatch.tap()
        app.buttons["book.continue"].tap()
        XCTAssertTrue(app.textViews["reader.transcript"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No timed transcript for this track"].exists)
        XCTAssertTrue(app.sliders["Track playback position"].exists)
    }

    @MainActor func testTipsCanBeDismissedAndResetWithoutDeletingBooks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--progressive-books-fixture", "--onboarding-fixture"]
        app.launch()
        app.staticTexts["Text example"].firstMatch.tap()
        app.buttons["book.continue"].tap()
        XCTAssertTrue(app.buttons["onboarding.got-it"].waitForExistence(timeout: 10))
        capture(app, name: "First reading tip")
        app.buttons["onboarding.got-it"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["library.settings"].tap()
        app.buttons["settings.reset-tips"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Text example"].firstMatch.exists)
        app.staticTexts["Text example"].firstMatch.tap()
        app.buttons["book.continue"].tap()
        XCTAssertTrue(app.buttons["onboarding.got-it"].waitForExistence(timeout: 5))
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
