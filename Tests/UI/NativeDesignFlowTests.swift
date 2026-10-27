import XCTest

final class NativeDesignFlowTests: XCTestCase {
    @MainActor func testTabNavigationKeepsDictionaryAndPracticeAvailable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        capture(app, "Native Glass — Library")
        app.tabBars.buttons["Dictionary"].tap()
        XCTAssertTrue(app.buttons["dictionary.entry.dzień dobry"].waitForExistence(timeout: 5))
        capture(app, "Native Glass — Dictionary")
        app.tabBars.buttons["Practice"].tap()
        XCTAssertTrue(app.buttons["practice.quick-start"].waitForExistence(timeout: 5))
        capture(app, "Native Glass — Practice")
        app.buttons["practice.quick-start"].tap()
        XCTAssertTrue(app.buttons["learn.preview-learn"].waitForExistence(timeout: 5))
        capture(app, "Native Glass — Preview")
        app.buttons["learn.preview-learn"].tap()
        XCTAssertTrue(app.buttons["learn.check"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["learn.original"].exists)
        app.buttons["learn.check"].tap()
        XCTAssertTrue(app.buttons["learn.right"].waitForExistence(timeout: 5))
        capture(app, "Native Glass — Answer")
        app.buttons["learn.right"].tap()
        XCTAssertTrue(app.staticTexts["Round complete"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["library.settings"].exists)
    }

    @MainActor func testEditorialReaderKeepsPlaybackAndReadingOptionsReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture"]
        app.launch()
        let story = app.staticTexts["Reading vocabulary story"].firstMatch
        XCTAssertTrue(story.waitForExistence(timeout: 10))
        capture(app, "Native Glass — Featured book")
        app.buttons["library.continue"].tap()
        XCTAssertTrue(app.textViews["reader.transcript"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Dictionary"].isHittable)
        XCTAssertTrue(app.buttons["Play"].exists)
        capture(app, "Editorial — Reader")
        app.buttons["Reading vocabulary"].tap()
        XCTAssertTrue(app.switches["reader.new-words"].waitForExistence(timeout: 5))
        app.buttons["reader.choose-chapter"].tap()
        XCTAssertTrue(app.buttons["reader.chapter.one"].waitForExistence(timeout: 5))
        capture(app, "Native Glass — Chapters")
    }

    @MainActor func testPracticeAtAccessibilityTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.tabBars.buttons["Practice"].tap()
        let quick = app.buttons["practice.quick-start"]
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
        if !quick.isHittable { app.swipeUp() }
        quick.tap()
        let learn = app.buttons["learn.preview-learn"]
        XCTAssertTrue(app.staticTexts["learn.translation"].waitForExistence(timeout: 5))
        for _ in 0..<8 {
            if learn.exists && learn.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(learn.isHittable)
        capture(app, "Native Glass — Accessibility text")
        learn.tap()
        let check = app.buttons["learn.check"]
        if !check.isHittable { app.swipeUp() }
        XCTAssertTrue(check.isHittable)
    }

    @MainActor func testInlinePhraseActionsKeepAnswerHiddenAndPresentTranslationEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        app.tabBars.buttons["Practice"].tap()
        app.buttons["practice.quick-start"].tap()
        app.buttons["learn.preview-learn"].tap()
        let translation = app.staticTexts["learn.translation"]
        let edit = app.buttons["learn.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Edit translation"].exists)
        XCTAssertFalse(app.buttons["learn.copy-translation"].exists)
        XCTAssertFalse(app.buttons["learn.copy-original"].exists)
        XCTAssertGreaterThanOrEqual(edit.frame.minX, translation.frame.maxX)
        XCTAssertEqual(edit.frame.midY, translation.frame.midY, accuracy: 2)
        edit.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["learn.check"].tap()
        let original = app.staticTexts["learn.original"]
        let copy = app.buttons["learn.copy-original"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(copy.frame.minX, original.frame.maxX)
        XCTAssertEqual(copy.frame.midY, original.frame.midY, accuracy: 2)
        XCTAssertFalse(app.buttons["learn.copy-source-context"].exists)
        copy.tap()
        XCTAssertEqual(copy.value as? String, "Copied")
        capture(app, "Practice card — Inline text actions")
    }

    @MainActor func testPreviewAudioModesHaveAnExplicitEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reading-vocabulary-fixture", "--audio-boundary-fixture", "--dual-audio-fixture"]
        app.launch()
        app.tabBars.buttons["Practice"].tap()
        app.buttons["practice.quick-start"].tap()
        let mode = app.buttons["learn.audio-mode"]
        let edit = app.buttons["learn.edit-audio"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(mode.value as? String, "Selected word")
        XCTAssertGreaterThanOrEqual(app.buttons["learn.play-audio"].frame.minY,
                                    app.staticTexts["learn.original"].frame.maxY)
        mode.tap()
        app.buttons["Whole phrase"].tap()
        XCTAssertEqual(mode.value as? String, "Whole phrase")
        capture(app, "Practice preview — Audio panel")
        edit.tap()
        let range = app.staticTexts["audio-editor.range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertTrue(range.label.replacingOccurrences(of: ",", with: ".").contains("0.50"))
        app.buttons["Cancel"].tap()
        mode.tap()
        app.buttons["Selected word"].tap()
        edit.tap()
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertTrue(range.label.replacingOccurrences(of: ",", with: ".").contains("1.50"))
        app.buttons["Cancel"].tap()
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension NativeDesignFlowTests {
    @MainActor func testSourceLanguagePickerSynchronizesDictionaryPracticeAndEmptyGroups() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture", "--multilingual-fixture"]
        app.launch()
        func destination(_ title: String) {
            let tab = app.tabBars.buttons[title]
            if tab.exists && tab.isHittable { tab.tap() }
            else {
                let sidebar = app.buttons["Toggle Sidebar"]
                if sidebar.exists && sidebar.isHittable { sidebar.tap() }
                let item = app.buttons[title].firstMatch
                if item.exists { item.tap() } else { app.staticTexts[title].firstMatch.tap() }
            }
        }
        func choose(_ language: String) {
            app.buttons["source-language.picker"].tap()
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", language)).firstMatch.tap()
        }
        destination("Dictionary")
        XCTAssertTrue(app.buttons["dictionary.entry.dzień dobry"].waitForExistence(timeout: 5))
        choose("English")
        XCTAssertTrue(app.buttons["dictionary.entry.English phrase 10"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["dictionary.entry.dzień dobry"].exists)
        XCTAssertEqual(app.staticTexts["dictionary.stats.level.1"].label, "10")
        destination("Practice")
        XCTAssertTrue(app.staticTexts["practice.ready-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["practice.ready-count"].label, "10 ready to repeat")
        app.buttons["source-language.picker"].tap()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Italian")).firstMatch.exists,
                       "Languages without books must not be selectable")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Polish")).firstMatch.tap()
        destination("Dictionary")
        choose("Polish")
        XCTAssertTrue(app.buttons["dictionary.entry.dzień dobry"].waitForExistence(timeout: 5))
    }

    @MainActor func testSinglePolishBookShowsFixedFlagInDictionaryAndPractice() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--learning-ux-fixture"]
        app.launch()
        for tab in ["Dictionary", "Practice"] {
            app.tabBars.buttons[tab].tap()
            let current = app.descendants(matching: .any)["source-language.current"]
            XCTAssertTrue(current.waitForExistence(timeout: 5))
            XCTAssertTrue(current.label.contains("🇵🇱"))
            XCTAssertFalse(app.buttons["source-language.picker"].exists)
        }
    }
}
