import XCTest

final class ReadingVocabularyFlowTests: XCTestCase {
    @MainActor private func openReader(_ app: XCUIApplication) {
        if app.buttons["library.continue"].exists {
            app.buttons["library.continue"].tap()
        } else {
            if !app.buttons["book.continue"].exists { app.staticTexts["Reading vocabulary story"].firstMatch.tap() }
            let resume = app.buttons["book.continue"]
            XCTAssertTrue(resume.waitForExistence(timeout: 5))
            for _ in 0..<5 where !resume.isHittable { app.swipeUp() }
            resume.tap()
        }
    }

    @MainActor func testBackAndReopenPreservesBookChapterProgress() {
        verifyBackAndReopenPreservesProgress(legacy: false)
    }

    @MainActor func testBackAndReopenPreservesLegacyChapterProgress() {
        verifyBackAndReopenPreservesProgress(legacy: true)
    }

    @MainActor private func verifyBackAndReopenPreservesProgress(legacy: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture"]
        if legacy { app.launchArguments.append("--legacy-reader-fixture") }
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10)); openReader(app)
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(app.staticTexts["0:10"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(story.waitForExistence(timeout: 5)); openReader(app)
        XCTAssertTrue(app.staticTexts["0:10"].waitForExistence(timeout: 5), "Back must preserve the saved chapter position")
        app.buttons["reader.choose-chapter"].tap()
        if legacy {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reader.chapter.")).firstMatch.tap()
        } else {
            app.buttons["reader.chapter.one"].tap()
        }
        XCTAssertTrue(app.staticTexts["0:00"].waitForExistence(timeout: 5), "Explicit selection still restarts the chapter")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(story.waitForExistence(timeout: 5)); openReader(app)
        XCTAssertTrue(app.staticTexts["0:00"].waitForExistence(timeout: 5))
    }

    @MainActor func testNaturalTransitionMarksPreviousChapterReadAndManualSelectionRestarts() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--chapter-end-fixture"]
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10)); openReader(app)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10))
        app.buttons["Play"].tap()
        let picker = app.buttons["reader.choose-chapter"]
        expectation(for: NSPredicate(format: "label == %@", "Chapter two"), evaluatedWith: picker)
        waitForExpectations(timeout: 10)
        app.buttons["Pause"].tap()
        picker.tap()
        app.buttons["reader.chapter.one"].tap()
        app.buttons["Reading vocabulary"].tap()
        app.buttons["reader.actions"].tap()
        let read = app.buttons["reader.complete-chapter"]
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: read)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(read.label, "Read")
        app.textViews["reader.transcript"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        XCTAssertTrue(app.staticTexts["vocabulary.statistics"].label.contains("New: 0"))
        XCTAssertTrue(app.staticTexts["0:00"].exists, "Manual chapter choice restarts at zero")
        picker.tap()
        app.buttons["reader.chapter.two"].tap()
        app.buttons["reader.actions"].tap()
        XCTAssertTrue(app.buttons["reader.complete-chapter"].isEnabled, "Manual selection must not complete the previous chapter")
    }

    @MainActor func testReselectingCurrentChapterScrollsToBeginning() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--paused-scroll-fixture"]
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10)); openReader(app)
        let text = app.textViews["reader.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.swipeUp(velocity: .fast)
        XCTAssertTrue(app.buttons["Follow audio"].exists)
        app.buttons["reader.choose-chapter"].tap()
        app.buttons["reader.chapter.one"].tap()
        let value = try XCTUnwrap(text.value as? String)
        let offset = try XCTUnwrap(Int(value.replacingOccurrences(of: "offset:", with: "")))
        XCTAssertLessThanOrEqual(offset, 5)
    }

    @MainActor func testManualSwipeWhilePausedWithNewWordHighlighting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--paused-scroll-fixture"]
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10)); openReader(app)
        let text = app.textViews["reader.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        app.buttons["Reading vocabulary"].tap()
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
        let story = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10)); openReader(app)
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
        let story = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10))
        let badge = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.vocabulary.")).firstMatch
        let initialCount = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "New", "4")
        expectation(for: initialCount, evaluatedWith: badge)
        waitForExpectations(timeout: 10)
        openReader(app)
        app.buttons["Reading vocabulary"].tap()
        app.buttons["reader.actions"].tap()
        let chapter = app.buttons["reader.complete-chapter"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 10))
        let stats = app.staticTexts["vocabulary.statistics"]
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        XCTAssertTrue(stats.label.contains("New: 2"))
        chapter.tap()
        XCTAssertTrue(app.alerts["Mark chapter read?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(stats.label.contains("New: 2"))
        app.buttons["reader.actions"].tap()
        XCTAssertTrue(chapter.isEnabled)
        chapter.tap()
        app.alerts.buttons["reader.confirm-completion"].firstMatch.tap()
        let noNew = NSPredicate(format: "label CONTAINS %@", "New: 0")
        expectation(for: noNew, evaluatedWith: stats)
        waitForExpectations(timeout: 10)
        app.buttons["reader.actions"].tap()
        XCTAssertFalse(chapter.isEnabled)
        app.textViews["reader.transcript"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        app.segmentedControls.buttons["Full text"].tap()
        let twoNew = NSPredicate(format: "label CONTAINS %@", "New: 2")
        expectation(for: twoNew, evaluatedWith: stats)
        waitForExpectations(timeout: 10)
        app.buttons["reader.actions"].tap()
        app.buttons["reader.complete-book"].tap()
        XCTAssertTrue(app.alerts["Mark whole book read?"].waitForExistence(timeout: 5))
        app.alerts.buttons["reader.confirm-completion"].firstMatch.tap()
        expectation(for: noNew, evaluatedWith: stats)
        waitForExpectations(timeout: 10)
        app.buttons["reader.actions"].tap()
        XCTAssertFalse(app.buttons["reader.complete-book"].isEnabled)
        app.textViews["reader.transcript"].coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        let toggle = app.switches["reader.new-words"]
        XCTAssertTrue(toggle.exists)
        toggle.tap()
        XCTAssertTrue(stats.label.contains("New: 0"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(story.waitForExistence(timeout: 5))
        // The featured card disappears on completion; query the remaining row
        // by its spoken count instead of retaining the removed card's element.
        let completedCount = NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "Unique word forms: 4", "New")
        XCTAssertTrue(app.descendants(matching: .any).matching(completedCount).firstMatch.waitForExistence(timeout: 10))
    }
}
