import XCTest

final class GeneratedImageUITests: XCTestCase {
    @MainActor
    func testAgentImageLoadsAndOpensFullScreen() {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-store-preview", "-threads-preview", "-images-preview",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-companion.onboarding.welcomeSeen", "YES",
            "-companion.onboarding.notificationsSeen", "YES"]
        app.launch()
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
        let image = app.buttons["Image: screenshot.png"]
        let appeared = image.waitForExistence(timeout: 5)
        record("Agent image in transcript", app)
        XCTAssertTrue(appeared)
        guard appeared else { return }
        let loaded = NSPredicate(format: "enabled == true AND value == %@", "Loaded")
        expectation(for: loaded, evaluatedWith: image)
        waitForExpectations(timeout: 10)
        image.tap()
        let canvas = app.otherElements["Image canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        record("Agent image full screen", app)
        canvas.swipeDown()
        XCTAssertTrue(image.waitForExistence(timeout: 5))
    }

    @MainActor
    private func record(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
