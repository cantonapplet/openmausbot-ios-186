import XCTest

/// The chat header carries the bot's face, which pushes its settings, and the
/// screen button, which opens whichever of the browser or the computer the
/// settings chose. Threads and Live calls are rows on the settings page.
extension XCUIApplication {
    /// The pushed bot-settings form, which has no navigation title.
    var botSettingsPage: XCUIElement { descendants(matching: .any)["bot-settings-page"] }

    /// The face at the top of a chat, which opens the bot's settings.
    @MainActor
    func openChatActions() -> Bool {
        let actions = buttons["header-bot-actions"]
        guard actions.waitForExistence(timeout: 10) else { return false }
        // The face sits in a header that re-renders on every streamed frame
        // for a busy bot, and a tap that lands while the chat is still
        // settling can be dropped. Try a few times, but never tap again once
        // the sheet is up — a tap on the card's backdrop would close it.
        for _ in 0..<3 {
            if botSettingsPage.exists { return true }
            actions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if botSettingsPage.waitForExistence(timeout: 5) { return true }
        }
        return botSettingsPage.exists
    }

    /// Face → Threads, which opens the thread picker.
    @MainActor
    func openThreadsFromHeader(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(openChatActions(), "bot settings", file: file, line: line)
        let threads = buttons["Threads"]
        XCTAssertTrue(threads.waitForExistence(timeout: 10), "Threads in bot settings", file: file, line: line)
        threads.tap()
        // Settings closes and the picker rises after it; wait for the picker
        // itself so callers do not tap into the gap between the two sheets.
        XCTAssertTrue(buttons["select-threads"].waitForExistence(timeout: 10), "thread picker", file: file, line: line)
    }

    /// Face → Start a Live call.
    @MainActor
    func tapStartCallFromHeader(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(openChatActions(), "bot settings", file: file, line: line)
        let start = buttons["Start a Live call"]
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Start a Live call in bot settings", file: file, line: line)
        start.tap()
    }

    /// Whether bot settings currently offers a call, then pops the page.
    @MainActor
    func chatCanStartCall() -> Bool {
        guard openChatActions() else { return false }
        let start = buttons["Start a Live call"]
        let exists = start.waitForExistence(timeout: 2)
        let back = navigationBars.buttons.firstMatch
        if back.exists { back.tap() }
        return exists
    }

    /// The thread the chat is on, from the settings button's value.
    @MainActor
    func chatThreadTitle() -> String? {
        buttons["header-bot-actions"].value as? String
    }
}
