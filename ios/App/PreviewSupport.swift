// Xcode canvas previews for the screens worth watching while editing.
//
// There are no `#Preview`s elsewhere in the app: every screen reads the
// shared `Session` and expects a paired computer, so a bare
// `#Preview { ChatView(...) }` crashes on a miss ing environment object.
// `PreviewHost` supplies what `CompanionApp` supplies at launch, with the
// session hydrated from a bundled fixture fleet instead of a network.
//
// Debug-only: these previews are a development tool, and the fixture JSON
// is not part of a Release build's behavior.
#if DEBUG
import SwiftUI
import CompanionCore

/// Stands in for `CompanionApp` while the canvas runs one view.
///
/// Internal rather than private so a `#Preview` can live beside the screen it
/// belongs to instead of only in this file.
struct PreviewHost<Content: View>: View {
    @State private var session: Session
    @State private var liveCall = LiveCallController.forThisLaunch()
    @AppStorage(PrefKey.appearance) private var appearance = AppAppearance.system.rawValue
    @AppStorage(PrefKey.language) private var language = AppLanguage.system.rawValue
    private let content: (Session) -> Content

    @MainActor
    init(fixture: String, @ViewBuilder content: @escaping (Session) -> Content) {
        _session = State(initialValue: Session.preview(fixture: fixture))
        self.content = content
    }

    var body: some View {
        content(session)
            .environmentObject(session)
            .environmentObject(liveCall)
            .environment(\.avatarLoader, AvatarLoader(session: session))
            // The canvas does not run CompanionApp, so the app-wide settings
            // have to be applied here as well or the canvas stays in the
            // system defaults while the real app changes.
            .environment(\.locale, AppLanguage.resolved(language).locale ?? .autoupdatingCurrent)
            .preferredColorScheme(AppAppearance(stored: appearance).colorScheme)
    }
}

/// The home list, in the comfortable density.
#Preview("Home") {
    PreviewHost(fixture: "RosterPreview") { _ in
        ChatListView()
    }
}

/// A conversation with several threads, narration and tool cards.
#Preview("Chat") {
    PreviewHost(fixture: "ThreadPreview") { session in
        if let bot = session.state.bots.first {
            ChatView(chat: .bot(bot))
        } else {
            Text("ThreadPreview.json has no bots")
        }
    }
}

/// A bot blocked on an approval.
#Preview("Approval") {
    PreviewHost(fixture: "ApprovalPreview") { session in
        if let bot = session.state.bots.first {
            ChatView(chat: .bot(bot))
        } else {
            Text("ApprovalPreview.json has no bots")
        }
    }
}
#endif
