import XCTest

final class ActivityDashboardFlowTests: XCTestCase {
    @MainActor func testPeriodsNavigationAndLanguageIsolation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--activity-fixture"]
        app.launch()
        app.buttons["Activity"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["activity.period"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["activity.card.words"].waitForExistence(timeout: 10))
        capture(app, "Activity — Week")
        app.segmentedControls.buttons["Day"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["activity.card.words"].label.contains("18"))
        capture(app, "Activity — Day")
        app.buttons["activity.previous"].tap()
        XCTAssertTrue(app.buttons["Today"].exists)
        app.buttons["Today"].tap()
        app.segmentedControls.buttons["Month"].tap()
        capture(app, "Activity — Month")
        app.buttons["activity.language"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'English'")).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["activity.card.words"].label.contains("0"))
        XCTAssertTrue(app.descendants(matching: .any)["activity.card.advanced"].label.contains("0"))
    }

    @MainActor func testEmptyActivityHasRealZerosAndNoFutureNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["Activity"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["activity.card.words"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["activity.card.words"].label.contains("0"))
        XCTAssertFalse(app.buttons["activity.next"].isEnabled)
        capture(app, "Activity — Empty")
    }


    @MainActor func testRussianDashboardAtAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--activity-fixture", "--test-russian-ui",
                               "--reset-interface-language", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.buttons["Активность"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["activity.period"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["activity.card.words"].waitForExistence(timeout: 10))
        capture(app, "Activity — Russian large text")
        app.swipeUp()
        capture(app, "Activity — Russian large text scrolled")
    }

    @MainActor func testRussianDashboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--activity-fixture", "--test-russian-ui", "--reset-interface-language"]
        app.launch()
        app.buttons["Активность"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["activity.card.words"].waitForExistence(timeout: 10))
        capture(app, "Активность — Неделя")
        app.segmentedControls.buttons["День"].tap()
        capture(app, "Активность — День")
        app.segmentedControls.buttons["Месяц"].tap()
        capture(app, "Активность — Месяц")
        app.swipeUp()
        capture(app, "Активность — Детали")
    }

    @MainActor func testPracticeAnswerAppearsInActivity() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Practice"].firstMatch.tap()
        app.buttons["practice.quick-start"].tap()
        XCTAssertTrue(app.buttons["learn.preview-learn"].waitForExistence(timeout: 5))
        app.buttons["learn.preview-learn"].tap()
        app.buttons["learn.check"].tap()
        app.buttons["learn.right"].tap()
        XCTAssertTrue(app.staticTexts["Round complete"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        app.buttons["Activity"].firstMatch.tap()
        let card = app.descendants(matching: .any)["activity.card.advanced"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.contains("1"))
    }

    @MainActor func testStatisticsStayCachedUntilLongPullToRefresh() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Activity"].firstMatch.tap()
        let count = app.descendants(matching: .any)["activity.card.advanced"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(count.label.contains("0"))
        app.buttons["Practice"].firstMatch.tap()
        app.buttons["practice.quick-start"].tap()
        XCTAssertTrue(app.buttons["learn.preview-learn"].waitForExistence(timeout: 5))
        app.buttons["learn.preview-learn"].tap()
        app.buttons["learn.check"].tap()
        app.buttons["learn.right"].tap()
        XCTAssertTrue(app.staticTexts["Round complete"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        app.buttons["Activity"].firstMatch.tap()
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        XCTAssertTrue(count.label.contains("0"), "Returning to Activity must preserve its cached snapshot")
        let scroll = app.scrollViews["activity.scroll"]
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
            .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '1'"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
        capture(app, "Activity — Explicit pull refresh")
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
