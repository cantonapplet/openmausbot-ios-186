import XCTest

/// Bundled offline fleet only; no API client or paired user data.
final class TranscriptPresentationUITests: XCTestCase {
    @MainActor
    func testPastedNotesHideWrappersAndClaudeUpdateOffersManualRecovery() {
        let app = launchPreview(detail: "full", update: true)
        XCTAssertTrue(contains("The pasted notes stay visible.", in: app))
        XCTAssertFalse(contains("<pasted-text", in: app))
        XCTAssertFalse(contains("</pasted-text>", in: app))
        XCTAssertTrue(app.buttons["Update Claude for me"].waitForExistence(timeout: 5))
        app.buttons["I'll do it myself"].tap()
        XCTAssertTrue(app.staticTexts["claude update"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Copy command"].exists)
        screenshot("Pasted notes and manual Claude update recovery", in: app)
    }

    @MainActor
    func testCompactionOpensItsSummaryWithoutShowingDigest() {
        let app = launchPreview(detail: "full", receipts: true)
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Context compacted")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertFalse(contains("Digest must stay hidden", in: app))
        chip.tap()
        XCTAssertTrue(app.staticTexts["Earlier context preserved for the next turn."].waitForExistence(timeout: 3))
        screenshot("Compaction summary opened", in: app)
    }

    /// Opening from Home lands on the very end of the transcript, not a
    /// frame above it: the newest message rests just above the composer.
    @MainActor
    func testOpeningAConversationLandsOnItsVeryEnd() {
        let app = launchPreview(detail: "hidden")
        let newest = app.staticTexts["The build failed because a dependency is missing."]
        let input = app.descendants(matching: .any).matching(identifier: "message-input").firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        // The opening landing settles over half a second.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThanOrEqual(newest.frame.maxY, input.frame.minY, "the end clears the composer")
        XCTAssertLessThan(input.frame.minY - newest.frame.maxY, 60,
                          "the transcript opens on its end, not above it")
        screenshot("Conversation opens on its end", in: app)
    }

    /// The keyboard lifts the transcript instead of covering its end: no
    /// custom scroll animation, just the system's own inset.
    @MainActor
    func testKeyboardLeavesTheNewestMessageVisible() {
        let app = launchPreview(detail: "hidden")
        let input = app.descendants(matching: .any).matching(identifier: "message-input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let newest = app.staticTexts["The build failed because a dependency is missing."]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(newest.frame.maxY, input.frame.minY, "the chat opens on its end")

        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // The keyboard settles with its own animation; then the end is
        // still the end, not tucked under the composer.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThanOrEqual(newest.frame.maxY, input.frame.minY,
                                 "the newest message stays above the raised composer")
        screenshot("Keyboard keeps the end of the chat in view", in: app)
    }

    @MainActor
    func testSearchTargetRevealsIntermediateReply() {
        let app = launchPreview(detail: "hidden", focused: true)
        let target = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "I found the failing check.")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isHittable)
        screenshot("Focused search result expands narration", in: app)
    }

    @MainActor
    func testHiddenFoldsNarrationAndWebhookPayloadCanBeExpanded() {
        let app = launchPreview(detail: "hidden")
        let fold = app.buttons["assistant-turn.preview-turn"]
        XCTAssertTrue(fold.waitForExistence(timeout: 5))
        XCTAssertEqual(fold.label, "Worked for 4s")
        XCTAssertTrue(app.staticTexts["The build failed because a dependency is missing."].exists)
        XCTAssertFalse(contains("Let me inspect", in: app))
        XCTAssertTrue(app.staticTexts["Triage the build failure."].exists)
        XCTAssertFalse(contains("AUTHENTICATED WEBHOOK", in: app))
        XCTAssertFalse(contains("Delivery ID", in: app))
        XCTAssertFalse(app.staticTexts["webhook-payload"].exists)
        // Pepper is still marked busy, but the turn's final reply is in:
        // nothing left to type.
        XCTAssertFalse(app.descendants(matching: .any)["typing-indicator"].exists, "a finished reply ends the typing")
        screenshot("Compact transcript with Hidden activity", in: app)

        fold.tap()
        XCTAssertTrue(contains("Let me inspect the build logs.", in: app))
        XCTAssertTrue(contains("I found the failing check.", in: app))
        screenshot("Expanded narration uses a single final bubble tail", in: app)
        fold.tap()
        XCTAssertFalse(contains("Let me inspect", in: app))

        app.buttons["Event payload"].tap()
        XCTAssertTrue(app.staticTexts["webhook-payload"].waitForExistence(timeout: 3))
        XCTAssertTrue(contains("checkout", in: app))
        screenshot("Webhook payload expanded on demand", in: app)
    }

    /// At Hidden a working bot's in-between messages are one grey status
    /// line above the composer, not bubbles (Omkar, 2026-10-03).
    @MainActor
    func testHiddenShowsLiveNarrationAsOneStatusLine() {
        let app = launchPreview(detail: "hidden", live: true)
        let line = app.descendants(matching: .any)["live-status-line"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.contains("The build failed because a dependency is missing."), line.label)
        XCTAssertFalse(contains("Let me inspect", in: app))
        XCTAssertFalse(app.buttons["assistant-turn.preview-turn"].exists, "nothing folds before the turn ends")
        // The dots say the bot is working; the line says what at.
        assertTypingBubbleInView(app)
        screenshot("Hidden: live narration as one status line", in: app)
    }

    /// The moment after a send: your message lands, then the turn starts and
    /// the bot's typing bubble appears under it, on screen above the composer.
    @MainActor
    func testTypingBubbleAppearsUnderYourMessageWhenTheTurnStarts() {
        for detail in ["hidden", "full"] {
            let app = launchPreview(detail: detail, typing: true)
            let sent = app.staticTexts["Can you check the Android build too?"]
            XCTAssertTrue(sent.waitForExistence(timeout: 5), detail)
            let typing = assertTypingBubbleInView(app)
            XCTAssertGreaterThanOrEqual(typing.frame.minY, sent.frame.maxY, "the bubble sits under your message (\(detail))")
            XCTAssertFalse(app.descendants(matching: .any)["live-status-line"].exists, "nothing said yet, so no status line (\(detail))")
            screenshot("Typing bubble after a send (\(detail))", in: app)
            app.terminate()
        }
    }

    @MainActor
    func testFullKeepsLiveNarrationAsBubbles() {
        let app = launchPreview(detail: "full", live: true)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Let me inspect the build logs.")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["live-status-line"].exists)
        screenshot("Full: live narration stays as bubbles", in: app)
    }

    @MainActor
    func testHiddenSuppressesLiveReasoning() {
        let app = launchPreview(detail: "hidden", reasoning: true)
        XCTAssertTrue(app.buttons["assistant-turn.preview-turn"].waitForExistence(timeout: 5))
        XCTAssertFalse(contains("Thinking…", in: app))
        // Thinking hidden, the bubble still says the bot is on it.
        assertTypingBubbleInView(app)
    }

    @MainActor
    func testFullKeepsLiveReasoningAvailable() {
        let app = launchPreview(detail: "full", reasoning: true)
        XCTAssertTrue(app.staticTexts["Thinking…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["assistant-turn.preview-turn"].exists)
    }

    /// The typing bubble is on screen, not merely in the tree: XCUITest
    /// reports an element scrolled out of sight as existing, so this asks
    /// for hittable, and for the bubble to end above the composer.
    @MainActor
    @discardableResult
    private func assertTypingBubbleInView(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let typing = app.descendants(matching: .any)["typing-indicator"]
        XCTAssertTrue(typing.waitForExistence(timeout: 5), "no typing bubble", file: file, line: line)
        XCTAssertEqual(typing.label, "Pepper is typing", file: file, line: line)
        let inView = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: typing)
        wait(for: [inView], timeout: 5)
        let composer = app.descendants(matching: .any)["message-input"]
        XCTAssertTrue(composer.exists, "no composer", file: file, line: line)
        XCTAssertLessThanOrEqual(typing.frame.maxY, composer.frame.minY, "the typing bubble runs under the composer", file: file, line: line)
        return typing
    }

    @MainActor
    private func launchPreview(detail: String, reasoning: Bool = false, focused: Bool = false, receipts: Bool = false, update: Bool = false, live: Bool = false, typing: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-store-preview", "-chat-presentation-preview",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-companion.prefs.activityDetail", detail,
            // These tests open Pepper from Home. Comfortable Home is flat,
            // so the row opens the remembered thread and the chat header
            // makes this fixture's Gmail thread explicit.
            "-companion.prefs.rosterDensity", "comfortable",
            "-companion.onboarding.welcomeSeen", "YES",
            "-companion.onboarding.notificationsSeen", "YES"
        ]
        if reasoning { app.launchArguments.append("-chat-reasoning-preview") }
        if focused { app.launchArguments.append("-chat-focus-preview") }
        if receipts { app.launchArguments.append("-chat-compaction-preview") }
        if update { app.launchArguments.append("-chat-update-preview") }
        if live { app.launchArguments.append("-chat-live-narration-preview") }
        if typing { app.launchArguments.append("-chat-typing-preview") }
        app.launch()
        let pepper = app.buttons["chat-row.preview-pepper"]
        XCTAssertTrue(pepper.waitForExistence(timeout: 10))
        pepper.tap()
        let header = app.buttons["header-bot-actions"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        // The row usually opens Gmail already. Switching again would reload
        // the thread and lose the focused-message reveal this fixture sets up.
        let onGmail = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Triage Gmail"), object: header
        )
        if XCTWaiter.wait(for: [onGmail], timeout: 3) != .completed {
            app.openThreadsFromHeader()
            let gmail = app.buttons["thread-preview-gmail"]
            XCTAssertTrue(gmail.waitForExistence(timeout: 5))
            gmail.tap()
        }
        return app
    }

    @MainActor
    private func contains(_ text: String, in app: XCUIApplication) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }

    @MainActor
    private func screenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
