import XCTest

final class LibraryFlowTests: XCTestCase {
    @MainActor
    func testBothFilePickersPresentDocumentBrowser() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        // Opening media first catches the competing-fileImporter regression.
        for identifier in ["import.media", "import.transcript"] {
            app.launch()
            app.buttons["library.upload"].tap()
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 20),
                          "The document picker should open for \(identifier)")
            app.terminate()
        }
    }

    @MainActor
    func testEmptyLibraryImportAndDictionary() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your library is empty"].waitForExistence(timeout: 10))
        app.buttons["library.upload"].tap()
        XCTAssertTrue(app.buttons["Choose audio or video"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose transcript"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["import.language"].exists)
        XCTAssertTrue(app.switches["import.split"].exists)
        XCTAssertFalse(app.buttons["Import"].isEnabled)
        app.buttons["Cancel"].tap()
        app.buttons["Dictionary"].tap()
        XCTAssertTrue(app.staticTexts["No saved phrases"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLearningRoundHidesAnswerThenShowsGlobalLearntList() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()

        app.buttons["Dictionary"].tap()
        let learn = app.buttons["dictionary.learn"]
        XCTAssertTrue(learn.waitForExistence(timeout: 5))
        learn.tap()
        let start = app.buttons["learn.start"]
        if !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.staticTexts["learn.original"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["learn.check"].exists)
        app.buttons["learn.preview-learn"].tap()

        XCTAssertTrue(app.staticTexts["learn.translation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["learn.original"].exists,
                       "The original must stay hidden before Check")
        XCTAssertFalse(app.buttons["learn.generate-context"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["learn.context-words"].firstMatch.exists)
        app.buttons["learn.check"].tap()
        XCTAssertTrue(app.staticTexts["learn.original"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Audio unavailable on this device"].exists)
        XCTAssertTrue(app.buttons["learn.generate-context"].exists)
        app.buttons["learn.right"].tap()

        XCTAssertTrue(app.staticTexts["Round complete"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All learnt phrases"].exists)
        let learntOriginals = app.staticTexts.matching(identifier: "learn.completion.original")
        XCTAssertEqual(learntOriginals.count, 1,
                       "Only valid global level-4 entries belong in the completion list")
        XCTAssertEqual(learntOriginals.firstMatch.label, "do widzenia",
                       "The global list includes entries learned before this round")
    }
    @MainActor
    func testLearningContextTranslationReplacesSavedTranslation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture", "--learning-context-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.learn"].tap()
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-learn"].tap()
        XCTAssertFalse(app.staticTexts["learn.context-translation"].exists)
        XCTAssertFalse(app.buttons["learn.use-context-translation"].exists)
        app.buttons["learn.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["learn.context-words"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["learn.context-translation"].label, "здравствуйте")
        let useTranslation = app.buttons["learn.use-context-translation"]
        app.swipeUp()
        useTranslation.tap()
        app.swipeDown()
        XCTAssertEqual(app.staticTexts["learn.translation"].label, "здравствуйте")
        XCTAssertFalse(useTranslation.exists)
        app.buttons["Close"].tap()
        app.buttons["dictionary.learn"].tap()
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-learn"].tap()
        XCTAssertEqual(app.staticTexts["learn.translation"].label, "здравствуйте")
    }

    @MainActor
    func testDictionaryStatisticsAndLearntSectionUpdateAfterDeletion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        for (level, expected) in [(1, "1"), (2, "0"), (3, "0"), (4, "1")] {
            let count = app.staticTexts["dictionary.stats.level.\(level)"]
            XCTAssertTrue(count.waitForExistence(timeout: 5))
            XCTAssertEqual(count.label, expected)
        }
        XCTAssertTrue(app.staticTexts["In progress"].exists)
        XCTAssertTrue(app.staticTexts["Learnt phrases"].exists)
        let learnt = app.buttons["dictionary.entry.do widzenia"]
        if !learnt.isHittable { app.swipeUp() }
        learnt.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(learnt.exists)
        XCTAssertTrue(app.buttons["dictionary.entry.dzień dobry"].exists)
        XCTAssertTrue(app.staticTexts["No learnt phrases yet"].exists)
        app.swipeDown()
        XCTAssertEqual(app.staticTexts["dictionary.stats.level.4"].label, "0")
    }

    @MainActor
    func testPreviewLevelActionsSaveAndSkipLearning() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for (action, level, count) in [("learn.preview-next-level", 2, "1"), ("learn.preview-known", 4, "2")] {
            app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
            app.launch()
            app.buttons["Dictionary"].tap()
            app.buttons["dictionary.learn"].tap()
            if !app.buttons["learn.start"].isHittable { app.swipeUp() }
            app.buttons["learn.start"].tap()
            XCTAssertTrue(app.staticTexts["learn.original"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["learn.right"].exists)
            XCTAssertFalse(app.buttons["learn.check"].exists)
            app.buttons[action].tap()
            XCTAssertTrue(app.staticTexts["Preview complete"].waitForExistence(timeout: 5))
            app.buttons["Close"].tap()
            XCTAssertEqual(app.staticTexts["dictionary.stats.level.\(level)"].label, count)
            XCTAssertEqual(app.staticTexts["dictionary.stats.level.1"].label, "0")
            app.terminate()
        }
    }

    @MainActor
    func testLevelTwoPreviewRequiresCheckAndProgressRowsFilter() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.filter.level.2"].tap()
        XCTAssertTrue(app.staticTexts["No phrases at this level"].exists)
        XCTAssertFalse(app.buttons["dictionary.entry.dzień dobry"].exists)
        app.buttons["dictionary.filter.reset"].tap()
        XCTAssertTrue(app.buttons["dictionary.entry.dzień dobry"].exists)
        app.buttons["dictionary.learn"].tap()
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-next-level"].tap()
        XCTAssertTrue(app.staticTexts["Preview complete"].waitForExistence(timeout: 5))
        app.buttons["Repeat"].tap()
        XCTAssertTrue(app.buttons["learn.check"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["learn.original"].exists)
        XCTAssertFalse(app.buttons["learn.preview-learn"].exists)
        app.buttons["learn.check"].tap()
        XCTAssertTrue(app.staticTexts["learn.original"].exists)
        XCTAssertTrue(app.buttons["learn.preview-learn"].exists)
        XCTAssertTrue(app.buttons["learn.preview-next-level"].exists)
        XCTAssertTrue(app.buttons["learn.preview-known"].exists)
    }

    @MainActor
    func testWrongAnswerRoundCannotSwipeDismissAndCanResumeAfterClose() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.learn"].tap()
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-learn"].tap()
        app.buttons["learn.check"].tap()
        app.buttons["learn.wrong"].tap()
        app.navigationBars["Learn"].swipeDown()
        XCTAssertTrue(app.buttons["learn.check"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Save and close"].waitForExistence(timeout: 5))
        app.buttons["Keep learning"].tap()
        XCTAssertTrue(app.buttons["learn.check"].exists)
        app.buttons["Close"].tap()
        app.buttons["Save and close"].tap()
        XCTAssertTrue(app.buttons["dictionary.resume"].waitForExistence(timeout: 5))
        app.buttons["dictionary.resume"].tap()
        app.buttons["learn.resume"].tap()
        XCTAssertTrue(app.staticTexts["Wrong attempts: 1"].exists)
        XCTAssertFalse(app.staticTexts["learn.original"].exists)
        app.buttons["learn.check"].tap()
        app.buttons["learn.right"].tap()
        XCTAssertTrue(app.staticTexts["Round complete"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertFalse(app.buttons["dictionary.resume"].exists)
        XCTAssertEqual(app.staticTexts["dictionary.stats.level.2"].label, "1")
    }

}
