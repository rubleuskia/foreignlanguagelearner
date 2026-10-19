import XCTest

final class ReadingVocabularyFlowTests: XCTestCase {
    @MainActor func testChapterConfirmationAndWholeBookCompletionUpdateCounts() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture"]
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"]
        XCTAssertTrue(story.waitForExistence(timeout: 10))
        let badge = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.vocabulary.")).firstMatch
        let initialCount = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "New", "4")
        expectation(for: initialCount, evaluatedWith: badge)
        waitForExpectations(timeout: 10)
        story.tap()
        let chapter = app.buttons["reader.complete-chapter"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        let stats = app.staticTexts["vocabulary.statistics"]
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        XCTAssertTrue(stats.label.contains("New: 2"))
        chapter.tap()
        XCTAssertTrue(app.alerts["Mark chapter read?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(chapter.isEnabled)
        XCTAssertTrue(stats.label.contains("New: 2"))
        chapter.tap()
        app.alerts.buttons["reader.confirm-completion"].firstMatch.tap()
        let noNew = NSPredicate(format: "label CONTAINS %@", "New: 0")
        expectation(for: noNew, evaluatedWith: stats)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(chapter.isEnabled)
        app.segmentedControls.buttons["Full text"].tap()
        let twoNew = NSPredicate(format: "label CONTAINS %@", "New: 2")
        expectation(for: twoNew, evaluatedWith: stats)
        waitForExpectations(timeout: 10)
        app.buttons["reader.complete-book"].tap()
        XCTAssertTrue(app.alerts["Mark whole book read?"].waitForExistence(timeout: 5))
        app.alerts.buttons["reader.confirm-completion"].firstMatch.tap()
        expectation(for: noNew, evaluatedWith: stats)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["reader.complete-book"].isEnabled)
        let toggle = app.switches["reader.new-words"]
        XCTAssertTrue(toggle.exists)
        toggle.tap()
        XCTAssertTrue(stats.label.contains("New: 0"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(story.waitForExistence(timeout: 5))
        let completedCount = NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "4", "New")
        expectation(for: completedCount, evaluatedWith: badge)
        waitForExpectations(timeout: 10)
    }
}
