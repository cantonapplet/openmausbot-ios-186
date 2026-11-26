import XCTest

/// Runs against the bundled ThreadPreview fleet: no paired computer, and the
/// preview has no API client, so nothing typed here can be sent anywhere.
final class ComposerReturnUITests: XCTestCase {
    /// Messages behaviour: the software keyboard's Return breaks the line and
    /// the arrow button on the chat bar is the only send.
    @MainActor
    func testKeyboardReturnInsertsANewlineInsteadOfSending() {
        let app = launchPreview()
        let pepper = app.buttons["chat-row.preview-pepper"]
        XCTAssertTrue(pepper.waitForExistence(timeout: 10))
        pepper.tap()
        let header = app.buttons["header-bot-actions"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let onGmail = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Triage Gmail"), object: header
        )
        if XCTWaiter.wait(for: [onGmail], timeout: 3) != .completed {
            app.openThreadsFromHeader()
            let gmail = app.buttons["thread-preview-gmail"]
            XCTAssertTrue(gmail.waitForExistence(timeout: 5))
            gmail.tap()
        }

        let input = app.descendants(matching: .any).matching(identifier: "message-input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("first line")

        let keys = app.keyboards.buttons
        let returnKey = keys.matching(NSPredicate(format: "label ==[c] 'return'")).firstMatch
        XCTAssertTrue(returnKey.waitForExistence(timeout: 5), "the keyboard should offer a plain return key")
        XCTAssertFalse(keys.matching(NSPredicate(format: "label ==[c] 'send'")).firstMatch.exists,
                       "the keyboard must not carry a second send key")
        returnKey.tap()
        input.typeText("second line")

        XCTAssertEqual(input.value as? String, "first line\nsecond line")
        recordScreenshot("Two-line draft after tapping the keyboard's return", in: app)
    }

    @MainActor
    private func launchPreview() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            "-store-preview", "-threads-preview",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-companion.onboarding.welcomeSeen", "YES",
            "-companion.onboarding.notificationsSeen", "YES"
        ]
        app.launch()
        if app.buttons["Connect computer"].exists {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(app.buttons["chat-row.preview-pepper"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func recordScreenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
