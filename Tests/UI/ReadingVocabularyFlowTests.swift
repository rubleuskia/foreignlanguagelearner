import XCTest

final class ReadingVocabularyFlowTests: XCTestCase {
    @MainActor func testManualSwipeWhilePausedWithNewWordHighlighting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--paused-scroll-fixture"]
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"]
        XCTAssertTrue(story.waitForExistence(timeout: 10)); story.tap()
        let text = app.textViews["reader.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["vocabulary.statistics"].waitForExistence(timeout: 10))
        app.buttons["Play"].tap()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5)); pause.tap()
        XCTAssertTrue(app.buttons["Play"].exists)
        func offset() throws -> Int {
            let value = try XCTUnwrap(text.value as? String)
            return try XCTUnwrap(Int(value.replacingOccurrences(of: "offset:", with: "")))
        }
        let initial = try offset()
        text.swipeUp(velocity: .fast)
        let first = try offset()
        XCTAssertGreaterThan(first, initial + 100, "Paused audio must not hold the transcript at its cue")
        XCTAssertTrue(app.buttons["Follow audio"].exists)
        text.swipeUp(velocity: .fast)
        let second = try offset()
        XCTAssertGreaterThan(second, first + 100, "Successive swipes must keep advancing after inertia settles")
        app.switches["reader.new-words"].tap()
        XCTAssertEqual(try offset(), second, accuracy: 5)
        app.switches["reader.new-words"].tap()
        XCTAssertEqual(try offset(), second, accuracy: 5, "Refreshing paint while paused must preserve the viewport")
        text.swipeDown(velocity: .fast)
        XCTAssertLessThan(try offset(), second - 100)
        XCTAssertTrue(app.buttons["Play"].exists, "Manual scrolling must leave playback paused")
    }

    @MainActor func testChapterListScrollsWhilePlaybackKeepsUpdating() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--chapter-scroll-fixture"]
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"]
        XCTAssertTrue(story.waitForExistence(timeout: 10)); story.tap()
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); play.tap()
        app.buttons["reader.choose-chapter"].tap()
        let list = app.collectionViews["reader.chapters-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let last = app.buttons["reader.chapter.chapter-100"]
        for _ in 0..<20 {
            if last.exists && last.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(last.isHittable, "Playback ticks must not reset chapter list scrolling")
        last.tap()
        let picker = app.buttons["reader.choose-chapter"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.label, "Chapter 100")
    }

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
