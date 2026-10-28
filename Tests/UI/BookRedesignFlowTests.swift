import XCTest

final class BookRedesignFlowTests: XCTestCase {
    @MainActor func testBookDetailsContinueAndChapterNavigationPreserveSavedPosition() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--test-russian-ui", "--reset-interface-language"]
        app.launch()
        let direct = app.buttons["library.continue"]
        XCTAssertTrue(direct.waitForExistence(timeout: 10))
        capture(app, "Redesign — Library")
        direct.tap()
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(app.staticTexts["0:10"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.staticTexts["Reading vocabulary story"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["О книге"].waitForExistence(timeout: 5))
        let resume = app.buttons["book.continue"]
        for _ in 0..<5 where !resume.isHittable { app.swipeUp() }
        XCTAssertTrue(resume.exists)
        capture(app, "Redesign — Book details")
        resume.tap()
        XCTAssertTrue(app.staticTexts["0:10"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let second = app.buttons["book.chapter.two"]
        for _ in 0..<6 where !second.isHittable { app.swipeUp() }
        XCTAssertTrue(second.isHittable)
        capture(app, "Redesign — Chapters")
        second.tap()
        XCTAssertTrue(app.buttons["reader.choose-chapter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["reader.choose-chapter"].label, "Chapter two")
    }

    @MainActor func testBundledCoverCanBeSelectedAndImportedWithoutNetwork() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--cover-import-fixture"]
        app.launch()
        app.buttons["library.upload"].tap()
        let cover = app.buttons["import.cover.cover-ornate"]
        XCTAssertTrue(cover.waitForExistence(timeout: 15))
        cover.tap()
        XCTAssertTrue(cover.isSelected)
        capture(app, "Redesign — Built-in cover gallery")
        let commit = app.buttons["import.commit"]
        for _ in 0..<8 where !commit.exists || !commit.isHittable { app.swipeUp() }
        XCTAssertTrue(commit.isHittable)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: commit)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        commit.tap()
        XCTAssertTrue(app.staticTexts["Book added"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        let title = app.staticTexts["Cover import example"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        XCTAssertTrue(app.navigationBars["About book"].waitForExistence(timeout: 5))
        capture(app, "Redesign — Imported cover")
    }

    @MainActor func testRussianBookDetailsAndLargeTextControlsRemainReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--test-russian-ui", "--reset-interface-language",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let title = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        XCTAssertTrue(app.navigationBars["О книге"].waitForExistence(timeout: 5))
        let button = app.buttons["book.continue"]
        for _ in 0..<12 where !button.exists || !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable)
        capture(app, "Redesign — Russian accessibility text")
        button.tap()
        XCTAssertTrue(app.textViews["reader.transcript"].waitForExistence(timeout: 10))
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
