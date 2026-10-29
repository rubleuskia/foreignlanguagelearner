import XCTest

final class LibraryFlowTests: XCTestCase {
    @MainActor
    func testBackupMenuLivesOnLibraryAndOpensImportPicker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        let backup = app.buttons["library.backup"]
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: backup)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        backup.tap()
        XCTAssertTrue(app.buttons["Backup Library"].firstMatch.waitForExistence(timeout: 5))
        let importButton = app.buttons["Import Library"]
        XCTAssertTrue(importButton.exists)
        importButton.tap()
        XCTAssertTrue(app.buttons["Browse"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["Cancel"].firstMatch.tap()
        app.buttons["Dictionary"].tap()
        XCTAssertFalse(app.buttons["library.backup"].exists)
        XCTAssertFalse(app.buttons["Transfer"].exists)
    }

    @MainActor
    func testQuickStartAndReadyFilter() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        XCTAssertEqual(app.staticTexts["dictionary.stats.level.1"].label, "1")
        XCTAssertEqual(app.staticTexts["dictionary.stats.level.4"].label, "1")
        XCTAssertEqual(app.staticTexts["dictionary.stats.level.2"].label, "0 (0)")
        XCTAssertFalse(app.staticTexts["Translation available"].exists)
        app.switches["dictionary.filter.ready"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["dictionary.filter.ready"].value as? String, "1")
        XCTAssertTrue(app.buttons["dictionary.entry.dzień dobry"].exists)
        XCTAssertFalse(app.buttons["dictionary.entry.do widzenia"].exists)
        app.buttons["dictionary.filter.level.2"].tap()
        XCTAssertTrue(app.staticTexts["No phrases ready to repeat"].exists)
        app.buttons["dictionary.quick-start"].tap()
        XCTAssertTrue(app.buttons["learn.preview-learn"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["learn.start"].exists)
    }

    @MainActor
    func testPracticeSettingsAreSeparateAndRequireExplicitSave() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["library.settings"].tap()
        XCTAssertFalse(app.textFields["settings.cooldown.level.1"].exists)
        XCTAssertTrue(app.secureTextFields["OpenAI API key"].exists)
        app.navigationBars["Settings"].buttons.firstMatch.tap()
        app.tabBars.buttons["Practice"].tap()
        app.buttons["practice.settings"].tap()
        let field = app.textFields["settings.cooldown.level.1"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let original = field.value as! String
        func replace(_ text: String) {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                  count: (field.value as? String ?? "").count) + text)
        }
        replace("25.5")
        app.navigationBars["Practice settings"].buttons.firstMatch.tap()
        app.buttons["practice.settings"].tap()
        XCTAssertEqual(field.value as? String, original, "Unsaved edits must be discarded")
        replace("25.5")
        app.buttons["settings.cooldown.save"].tap()
        XCTAssertTrue(app.staticTexts["Cooldown settings saved."].exists)
        app.navigationBars["Practice settings"].buttons.firstMatch.tap()
        app.buttons["practice.settings"].tap()
        XCTAssertEqual(field.value as? String, "25.5")
        replace(original)
        app.buttons["settings.cooldown.save"].tap()
    }

    @MainActor
    func testBothFilePickersPresentDocumentBrowser() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        // Opening media first catches the competing-fileImporter regression.
        for identifier in ["import.media", "import.transcript"] {
            app.launch()
            app.buttons["library.upload"].tap()
            app.buttons["Audio or video with SRT / VTT subtitles"].tap()
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
        XCTAssertTrue(app.staticTexts["What do you have?"].waitForExistence(timeout: 5))
        app.buttons["Audio or video with SRT / VTT subtitles"].tap()
        XCTAssertTrue(app.buttons["Choose audio or video"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose transcript"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["import.language"].exists)
        XCTAssertTrue(app.switches["import.split"].exists)
        XCTAssertFalse(app.buttons["Import"].isEnabled)
        app.navigationBars["Add material"].buttons["Cancel"].tap()
        app.navigationBars["Add book"].buttons["Cancel"].tap()
        app.buttons["Dictionary"].tap()
        XCTAssertTrue(app.staticTexts["No saved phrases"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLearningRoundHidesAnswerThenShowsOnlyRoundResults() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()

        app.buttons["Dictionary"].tap()
        let learn = app.buttons["dictionary.learn"]
        XCTAssertTrue(learn.waitForExistence(timeout: 5))
        learn.tap()
        XCTAssertTrue(app.descendants(matching: .any)["learn.ignore-cooldown"].firstMatch.waitForExistence(timeout: 5))
        let start = app.buttons["learn.start"]
        if !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.staticTexts["learn.original"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["learn.check"].exists)
        app.buttons["learn.preview-learn"].tap()

        XCTAssertTrue(app.buttons["learn.translation"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["Round results"].exists)
        let learntOriginals = app.staticTexts.matching(identifier: "learn.completion.original")
        XCTAssertEqual(learntOriginals.count, 1,
                       "Only entries from this round belong in the completion list")
        XCTAssertFalse(learntOriginals.allElementsBoundByIndex.contains { $0.label == "do widzenia" })
        XCTAssertEqual(app.staticTexts["learn.completion.level-transition"].label, "Level 1 to 2")
    }
    @MainActor
    func testPreviewSkipLeavesWordAtSameLevelForAnotherRound() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.learn"].tap()
        XCTAssertTrue(app.buttons["learn.start"].waitForExistence(timeout: 5))
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-skip"].tap()
        XCTAssertTrue(app.staticTexts["Preview complete"].waitForExistence(timeout: 5))
        app.buttons["Repeat"].tap()
        XCTAssertTrue(app.buttons["learn.preview-skip"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertEqual(app.staticTexts["dictionary.stats.level.1"].label.components(separatedBy: " ").first, "1")
    }

    @MainActor
    func testLearningSwipesAndUndo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.learn"].tap()
        XCTAssertTrue(app.buttons["learn.start"].waitForExistence(timeout: 5))
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-learn"].tap()
        let translation = app.buttons["learn.translation"]
        translation.swipeLeft()
        XCTAssertTrue(app.buttons["learn.check"].exists)
        XCTAssertFalse(app.buttons["learn.undo"].exists)
        translation.tap()
        XCTAssertTrue(app.staticTexts["learn.original"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["learn.swipe-hint"].firstMatch.exists)
        translation.tap()
        XCTAssertFalse(app.staticTexts["learn.original"].exists)
        translation.tap()
        translation.swipeRight()
        app.buttons["learn.undo"].tap()
        XCTAssertTrue(app.staticTexts["learn.original"].exists)
        XCTAssertTrue(app.staticTexts["Wrong attempts: 0"].exists)
        translation.swipeLeft()
        app.buttons["learn.undo"].tap()
        XCTAssertTrue(app.staticTexts["learn.original"].exists)
        XCTAssertFalse(app.staticTexts["Round complete"].exists)
        translation.swipeLeft()
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
        XCTAssertTrue(app.buttons["learn.start"].waitForExistence(timeout: 5))
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
        XCTAssertEqual(app.buttons["learn.translation"].label, "здравствуйте")
        XCTAssertFalse(useTranslation.exists)
        app.buttons["Close"].tap()
        app.buttons["dictionary.learn"].tap()
        XCTAssertTrue(app.buttons["learn.start"].waitForExistence(timeout: 5))
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-learn"].tap()
        XCTAssertEqual(app.buttons["learn.translation"].label, "здравствуйте")
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
            XCTAssertEqual(count.label.components(separatedBy: " ").first, expected)
        }
        XCTAssertTrue(app.staticTexts["In progress"].exists)
        XCTAssertTrue(app.staticTexts["Learnt phrases"].exists)
        let learnt = app.buttons["dictionary.entry.do widzenia"]
        if !learnt.isHittable || learnt.frame.maxY > app.tabBars.firstMatch.frame.minY {
            app.swipeUp()
        }
        learnt.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(learnt.exists)
        XCTAssertTrue(app.buttons["dictionary.entry.dzień dobry"].exists)
        XCTAssertTrue(app.staticTexts["No learnt phrases yet"].exists)
        app.swipeDown()
        XCTAssertEqual(app.staticTexts["dictionary.stats.level.4"].label.components(separatedBy: " ").first, "0")
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
            XCTAssertTrue(app.buttons["learn.start"].waitForExistence(timeout: 5))
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
            app.buttons["learn.start"].tap()
            XCTAssertTrue(app.staticTexts["learn.original"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["learn.right"].exists)
            XCTAssertFalse(app.buttons["learn.check"].exists)
            app.buttons[action].tap()
            XCTAssertTrue(app.staticTexts["Preview complete"].waitForExistence(timeout: 5))
            app.buttons["Close"].tap()
            XCTAssertEqual(app.staticTexts["dictionary.stats.level.\(level)"].label.components(separatedBy: " ").first, count)
            XCTAssertEqual(app.staticTexts["dictionary.stats.level.1"].label.components(separatedBy: " ").first, "0")
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
        app.switches["learn.ignore-cooldown"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["learn.start"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["learn.start"].waitForExistence(timeout: 5))
        if !app.buttons["learn.start"].isHittable { app.swipeUp() }
        app.buttons["learn.start"].tap()
        app.buttons["learn.preview-learn"].tap()
        app.buttons["learn.check"].tap()
        app.buttons["learn.wrong"].tap()
        app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", "Learn")).firstMatch.swipeDown()
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
        XCTAssertEqual(app.staticTexts["dictionary.stats.level.2"].label.components(separatedBy: " ").first, "1")
    }

    @MainActor
    func testRussianTranslationCopySharesTextRow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.buttons["Dictionary"].tap()
        app.buttons["dictionary.entry.dzień dobry"].tap()
        let text = app.staticTexts["dictionary.detail-translation"]
        let copy = app.buttons["dictionary.copy-translation"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.exists)
        XCTAssertLessThan(copy.frame.minY, text.frame.maxY)
        XCTAssertGreaterThanOrEqual(copy.frame.minX, text.frame.maxX)
        copy.tap()
        XCTAssertEqual(copy.value as? String, "Copied")
    }

}
