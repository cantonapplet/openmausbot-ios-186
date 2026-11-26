import XCTest

/// Runs against the bundled RosterPreview fleet: no account, paired computer,
/// or server is involved.
final class RosterDensityUITests: XCTestCase {
    @MainActor
    func testLongPressListsThreadsAndNewThread() {
        let app = launchRoster()
        let row = app.buttons["chat-row.roster-pepper"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        // No inline disclosure arrow on the row itself.
        XCTAssertFalse(app.buttons["threads-disclosure.roster-pepper"].exists)

        row.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["Threads"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pin"].exists)
        XCTAssertTrue(app.buttons["Bot settings"].exists)
        XCTAssertTrue(app.buttons["Delete bot"].exists)
        recordScreenshot("Bot long-press menu", in: app)

        let settings = app.buttons["Bot settings"].firstMatch
        settings.tap()
        XCTAssertTrue(app.botSettingsPage.waitForExistence(timeout: 8), "bot settings pushes")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        row.press(forDuration: 0.6)
        app.buttons["Threads"].tap()
        let gmail = app.buttons["Triage Gmail"].firstMatch
        XCTAssertTrue(gmail.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Triage iCloud"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Plan weekend"].firstMatch.exists)
        XCTAssertTrue(app.buttons["New thread"].firstMatch.exists)
        recordScreenshot("Threads submenu", in: app)
        gmail.tap()
        assertThread("Triage Gmail", in: app)
        app.buttons["Back"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["threads-disclosure.roster-pepper"].exists)
    }

    @MainActor
    func testPinningMovesBotToTop() {
        let app = launchRoster()
        let atlas = app.buttons["chat-row.roster-atlas"]
        let scout = app.buttons["chat-row.roster-scout"]
        XCTAssertTrue(atlas.waitForExistence(timeout: 10))
        XCTAssertTrue(scout.exists)

        atlas.press(forDuration: 0.9)
        let pin = app.buttons["Pin"].firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertLessThan(atlas.frame.minY, scout.frame.minY, "pinned bot moves above the unpinned rows")
        recordScreenshot("Pinned bot at the top", in: app)

        atlas.press(forDuration: 0.9)
        let unpin = app.buttons["Unpin"].firstMatch
        XCTAssertTrue(unpin.waitForExistence(timeout: 5))
        unpin.tap()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThan(atlas.frame.minY, scout.frame.minY, "unpinned bot returns to order")
    }

    /// A single-thread bot's row opens that conversation.
    @MainActor
    func testSingleThreadBotRowOpensItsThread() {
        let app = launchRoster()
        let atlas = app.buttons["chat-row.roster-atlas"]
        XCTAssertTrue(atlas.waitForExistence(timeout: 10))
        atlas.tap()
        assertThread("Weekly plan", in: app)
    }

    /// The floating Updates bar must never cover the last row.
    @MainActor
    func testLastRowClearsTheBottomBar() {
        let app = launchRoster()
        let bar = app.buttons["updates-button"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let last = app.buttons["chat-row.roster-sage"]
        var swipes = 0
        while !(last.exists && last.isHittable), swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(last.frame.maxY, bar.frame.minY - 8)
        recordScreenshot("Last row above the bar", in: app)
    }

    /// The list runs under the header; its first row starts below the controls.
    @MainActor
    func testFirstRowClearsTheHeader() {
        let app = launchRoster()
        let list = app.scrollViews["roster-list"]
        let searchButton = app.buttons["Search"]
        let firstRow = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-row."))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        XCTAssertTrue(list.exists)
        XCTAssertGreaterThanOrEqual(firstRow.frame.minY, searchButton.frame.maxY + 12)
        recordScreenshot("First row below the header", in: app)
    }

    // MARK: - Helpers

    private static let baseArguments = [
        "-store-preview", "-roster-preview",
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "-companion.onboarding.welcomeSeen", "YES",
        "-companion.onboarding.notificationsSeen", "YES",
        "-companion.prefs.updatesPill", "YES",
    ]

    @MainActor
    private func launchRoster() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = Self.baseArguments
        app.launch()
        if app.buttons["Connect computer"].exists {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(app.buttons["updates-button"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func assertThread(_ title: String, in app: XCUIApplication) {
        let header = app.buttons["header-bot-actions"]
        let expected = NSPredicate(format: "value == %@", title)
        let appeared = XCTNSPredicateExpectation(predicate: expected, object: header)
        XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 10), .completed)
    }

    @MainActor
    private func assertMissing(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func recordScreenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
