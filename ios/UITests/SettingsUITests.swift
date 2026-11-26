import XCTest

/// Bundled offline roster only: no paired computer and no network.
final class SettingsUITests: XCTestCase {
    private static let base: [String] = [
        "-store-preview", "-roster-preview",
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "-companion.onboarding.welcomeSeen", "YES",
        "-companion.onboarding.notificationsSeen", "YES",
    ]

    @MainActor
    func testAppearanceCanBeForcedAndIsRemembered() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        // No appearance launch argument: the argument domain outranks the
        // value the picker writes, which would pin it for the whole session.
        app.launchArguments = Self.base
        app.launch()
        openSettings(in: app)

        let theme = app.buttons["appearance"]
        XCTAssertTrue(theme.waitForExistence(timeout: 10))
        record("Settings", in: app)

        // Move through both explicit choices, whatever this simulator saved.
        theme.tap()
        XCTAssertTrue(app.buttons["Light"].waitForExistence(timeout: 5))
        app.buttons["Light"].tap()
        XCTAssertTrue(waitFor(app.buttons["appearance"], toShow: "Light"), "the picker shows Light")

        app.buttons["appearance"].tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 5))
        app.buttons["Dark"].tap()
        XCTAssertTrue(waitFor(app.buttons["appearance"], toShow: "Dark"), "the picker shows Dark")
        record("Settings forced dark", in: app)

        // Kept on this device across launches.
        app.terminate()
        app.launchArguments = Self.base
        app.launch()
        openSettings(in: app)
        XCTAssertTrue(app.buttons["appearance"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(app.buttons["appearance"], toShow: "Dark"), "Dark survived relaunch")
        record("Settings returned dark", in: app)

        // Leave the simulator in its default look for later tests.
        app.buttons["appearance"].tap()
        XCTAssertTrue(app.buttons["System"].waitForExistence(timeout: 5))
        app.buttons["System"].tap()
    }

    @MainActor
    private func waitFor(_ picker: XCUIElement, toShow value: String) -> Bool {
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", value, value),
            object: picker
        )
        return XCTWaiter.wait(for: [shown], timeout: 5) == .completed
    }

    @MainActor
    func testAccountMenuOffersSettingsAndRoutineCalendar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = Self.base
        app.launch()
        if app.buttons["Connect computer"].exists {
            app.terminate()
            app.launch()
        }

        let account = app.buttons["account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10), "the account button on the roster")
        account.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Routine calendar"].exists)
        record("Account menu", in: app)

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        record("Settings from the account menu", in: app)
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        if app.buttons["Connect computer"].exists {
            app.terminate()
            app.launch()
        }
        let account = app.buttons["account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10), "the account button on the roster")
        account.tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings in the account menu")
        settings.tap()
    }

    @MainActor
    private func record(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
