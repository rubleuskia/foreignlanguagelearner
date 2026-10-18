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
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.staticTexts["learn.original"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["learn.check"].exists)
        app.buttons["learn.preview-learn"].tap()

        XCTAssertTrue(app.staticTexts["learn.translation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["learn.original"].exists,
                       "The original must stay hidden before Check")
        XCTAssertFalse(app.buttons["learn.generate-context"].exists)
        XCTAssertFalse(app.staticTexts["learn.context-words"].exists)
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
    func testLearningSwipesAndUndo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.learn"].tap()
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-learn"].tap()
        let translation = app.staticTexts["learn.translation"]
        translation.swipeRight()
        XCTAssertTrue(app.buttons["learn.check"].exists)
        XCTAssertFalse(app.buttons["learn.undo"].exists)
        app.buttons["learn.check"].tap()
        translation.swipeLeft()
        app.buttons["learn.undo"].tap()
        XCTAssertTrue(app.staticTexts["learn.original"].exists)
        XCTAssertTrue(app.staticTexts["Wrong attempts: 0"].exists)
        translation.swipeRight()
        app.buttons["learn.undo"].tap()
        XCTAssertTrue(app.staticTexts["learn.original"].exists)
        XCTAssertFalse(app.staticTexts["Round complete"].exists)
        translation.swipeRight()
        XCTAssertTrue(app.staticTexts["Round complete"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["learn.undo"].waitForNonExistence(timeout: 4))
    }

    @MainActor
    func testLearningContextTranslationReplacesSavedTranslation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture", "--learning-context-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.learn"].tap()
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-learn"].tap()
        XCTAssertFalse(app.staticTexts["learn.context-translation"].exists)
        XCTAssertFalse(app.buttons["learn.use-context-translation"].exists)
        app.buttons["learn.check"].tap()
        XCTAssertTrue(app.staticTexts["learn.context-words"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["learn.context-translation"].label, "здравствуйте")
        let useTranslation = app.buttons["learn.use-context-translation"]
        app.swipeUp()
        useTranslation.tap()
        app.swipeDown()
        XCTAssertEqual(app.staticTexts["learn.translation"].label, "здравствуйте")
        XCTAssertFalse(useTranslation.exists)
        app.buttons["Close"].tap()
        app.buttons["dictionary.learn"].tap()
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

}
