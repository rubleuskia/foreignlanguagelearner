import XCTest

final class InterfaceLanguageFlowTests: XCTestCase {
    @MainActor func testRussianDefaultAndEnglishSwitchAcrossTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--test-russian-ui", "--reset-interface-language", "--learning-ux-fixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Библиотека"].waitForExistence(timeout: 10))
        app.buttons["library.settings"].tap()
        let picker = app.buttons["settings.interface-language"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["English"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Practice"].exists)
        app.tabBars.buttons["Dictionary"].tap()
        app.buttons["dictionary.practice"].tap()
        XCTAssertTrue(app.navigationBars["Practice"].waitForExistence(timeout: 5))
    }
}
