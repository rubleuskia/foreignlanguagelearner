import XCTest

final class CloudSettingsFlowTests: XCTestCase {
    @MainActor func testUnconfiguredBuildCannotPurchaseAndProviderModeIsExplicit() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        XCTAssertTrue(app.buttons["library.settings"].waitForExistence(timeout: 10))
        app.buttons["library.settings"].tap()
        let disabled = app.staticTexts["cloud.not-configured"]
        XCTAssertTrue(disabled.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Restore purchases"].exists)
        let mode = app.buttons["settings.provider-mode"]
        for _ in 0..<4 where !mode.isHittable { app.swipeUp() }
        XCTAssertTrue(mode.exists); mode.tap()
        app.buttons["Subscription"].firstMatch.tap()
        XCTAssertFalse(app.secureTextFields["OpenAI API key"].exists)
        mode.tap(); app.buttons["Personal API key"].firstMatch.tap()
        let personalKey = app.secureTextFields["OpenAI API key"]
        for _ in 0..<6 where !personalKey.exists { app.swipeUp() }
        XCTAssertTrue(personalKey.waitForExistence(timeout: 5))
    }
}
