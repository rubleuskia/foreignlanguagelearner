import XCTest

final class CatalogNavigationFlowTests: XCTestCase {
    @MainActor func testRequestsOpenBooksAndStayOpenAcrossStatusUpdates() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--catalog-navigation-fixture"]
        app.launch()
        let tab = app.tabBars.buttons["Catalog"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15)); tab.tap()
        let requests = app.buttons["catalog.requests"]
        XCTAssertTrue(requests.waitForExistence(timeout: 10)); requests.tap()
        for title in ["Antek", "Lalka"] {
            let row = app.buttons["catalog.request.\(title.lowercased())"]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            let detail = app.navigationBars[title]
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Download and import book"].exists)
            // The app's normal polling loop changes fixture statuses every five seconds.
            // Detect even a transient pop while the selected book is open.
            let popped = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: detail)
            popped.isInverted = true
            wait(for: [popped], timeout: 7)
            XCTAssertTrue(detail.exists)
            detail.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Import requests"].waitForExistence(timeout: 5))
        }
        app.navigationBars["Import requests"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Catalog after returning from import requests"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
