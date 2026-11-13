import XCTest

final class BuiltinLibraryFlowTests: XCTestCase {
    @MainActor func testCatalogShowsAuthorsAndOpensExistingBookWithoutAnotherDownload() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--builtin-library-fixture", "--test-russian-ui", "--reset-interface-language"]
        app.launch()
        let library = app.buttons["library.builtin"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        XCTAssertTrue(app.staticTexts["Bolesław Prus"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Lewis Carroll"].exists)
        XCTAssertTrue(app.staticTexts["Уже в библиотеке"].exists)
        XCTAssertFalse(app.buttons["builtin.download.lalka"].exists)
        XCTAssertTrue(app.buttons["builtin.download.carroll-alicja-w-krainie-czarow"].exists)
        app.buttons["Об авторе"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Польский писатель и журналист")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Источник"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "S3 library — covers, authors and imported status"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["builtin.open.lalka"].tap()
        XCTAssertTrue(app.navigationBars["О книге"].waitForExistence(timeout: 5))
    }
}
