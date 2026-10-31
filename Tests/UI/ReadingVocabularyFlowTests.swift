import XCTest

final class ReadingVocabularyFlowTests: XCTestCase {
    @MainActor func testCompactReaderMovesNewWordsIntoOverflowMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--phrase-pages-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["library.continue"].waitForExistence(timeout: 10))
        openReader(app)
        XCTAssertTrue(app.staticTexts["reader.page-number"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.segmentedControls["Reading mode"].exists)
        XCTAssertFalse(app.buttons["reader.vocabulary-details"].exists)
        XCTAssertFalse(app.switches["reader.new-words"].exists)
        app.buttons["book.resources"].tap()
        let toggle = app.descendants(matching: .any)["reader.new-words"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
    }

    @MainActor func testAudioAdvancesWholePhrasePagesAndFollowStaysAtBottom() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--phrase-pages-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["library.continue"].waitForExistence(timeout: 10))
        openReader(app)
        let number = app.staticTexts["reader.page-number"]
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        XCTAssertTrue(number.label.hasPrefix("1 /"))
        app.buttons["Play"].tap()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = Int(number.label.components(separatedBy: " / ")[0]) ?? 0
            return current > 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed)
        app.buttons["Pause"].tap()
        let audioPage = number.label
        app.buttons["Next page"].tap()
        let follow = app.buttons["Follow audio"]
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(follow.frame.midY, app.textViews["reader.transcript"].frame.maxY)
        follow.tap()
        XCTAssertEqual(number.label, audioPage)
    }

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
        text.swipeLeft()
        XCTAssertTrue(app.buttons["Follow audio"].exists)
        app.buttons["reader.choose-chapter"].tap()
        app.buttons["reader.chapter.one"].tap()
        let number = app.staticTexts["reader.page-number"]
        XCTAssertTrue(number.waitForExistence(timeout: 10))
        XCTAssertTrue(number.label.hasPrefix("1 /"))
    }

    @MainActor func testManualSwipeWhilePausedWithNewWordHighlighting() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--paused-scroll-fixture"]
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10)); openReader(app)
        let text = app.textViews["reader.transcript"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        // The reader opens paused. Starting this 20-second fixture here makes
        // XCTest wait through continuous cue changes and enter the next chapter.
        XCTAssertTrue(app.buttons["Play"].exists)
        func offset() throws -> Int {
            let value = app.staticTexts["reader.page-number"].label
            return try XCTUnwrap(Int(value.components(separatedBy: " / ")[0]))
        }
        let initial = try offset()
        XCTAssertLessThanOrEqual(text.frame.width, app.frame.width + 1,
                                 "A book page must wrap within the screen width")
        text.swipeLeft()
        let first = try offset()
        XCTAssertEqual(text.frame.minX, 0, accuracy: 1, "The settled page must align with the viewport")
        XCTAssertEqual(first, initial + 1, "A horizontal swipe must advance one whole page")
        XCTAssertTrue(app.buttons["Follow audio"].exists)
        app.buttons["Next page"].tap()
        let second = try offset()
        XCTAssertEqual(second, first + 1)
        app.buttons["book.resources"].tap()
        app.descendants(matching: .any)["reader.new-words"].firstMatch.tap()
        app.staticTexts["reader.page-number"].tap()
        XCTAssertEqual(try offset(), second)
        app.buttons["book.resources"].tap()
        app.descendants(matching: .any)["reader.new-words"].firstMatch.tap()
        app.staticTexts["reader.page-number"].tap()
        XCTAssertEqual(try offset(), second, "Refreshing paint while paused must preserve the page")
        app.buttons["Previous page"].tap()
        XCTAssertEqual(try offset(), second - 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Follow audio"].tap()
        XCTAssertEqual(try offset(), initial, "Follow audio must return to the current cue's page")
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
        let toggle = app.descendants(matching: .any)["reader.new-words"].firstMatch
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
