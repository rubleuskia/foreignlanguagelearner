import XCTest

final class CloudAlignmentFlowTests: XCTestCase {
    @MainActor func testWizardValidatesAndRestoresDraftAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        func openWizard() {
            app.launch()
            let menu = app.buttons["library.add-menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 15)); menu.tap()
            app.buttons["library.cloud-alignment"].tap()
            XCTAssertTrue(app.textFields["alignment.title"].waitForExistence(timeout: 10))
        }
        openWizard()
        XCTAssertTrue(app.buttons["alignment.audio"].exists)
        XCTAssertTrue(app.buttons["alignment.text"].exists)
        XCTAssertFalse(app.buttons["alignment.upload"].isEnabled)
        let field = app.textFields["alignment.title"]
        field.tap()
        if let previous = field.value as? String, previous != "Book title" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        field.typeText("Alignment draft persistence")
        app.buttons["Done"].tap()
        app.buttons["library.add-menu"].tap()
        app.buttons["library.cloud-alignment"].tap()
        XCTAssertEqual(app.textFields["alignment.title"].value as? String, "Alignment draft persistence")
        app.terminate()
        openWizard()
        XCTAssertEqual(app.textFields["alignment.title"].value as? String, "Alignment draft persistence")
        XCTAssertFalse(app.buttons["alignment.upload"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cloud alignment wizard"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
