// Where the chat's preferences are stored.
//
// `@AppStorage` rather than an observable object on purpose: the settings
// screen writes these and the chat reads them, and AppStorage already keeps
// both in step through UserDefaults. One place for the key strings is the
// only thing a shared type is needed for.
import Foundation
import SwiftUI
import CompanionCore

enum PrefKey {
    static let activityDetail = "companion.prefs.activityDetail"
    static let appearance = "companion.prefs.appearance"
    static let language = "companion.prefs.language"
    /// Per device, like the desktop's sidebar density: a phone and a laptop
    /// have different room for a list.
    static let rosterDensity = "companion.prefs.rosterDensity"
    /// Live calls: speaker (true, the default) or earpiece. A phone-side choice.
    static let liveSpeaker = "companion.prefs.liveSpeaker"
    /// What the chat header's screen button opens. Shared by every bot.
    static let screenTarget = "companion.prefs.screenTarget"
    /// Home's bottom status pill. Off unless asked for.
    static let updatesPill = "companion.prefs.updatesPill"
}

/// Which of a bot's screens the chat header and Settings open.
enum ScreenTarget: String, CaseIterable, Identifiable {
    case browser
    case computer

    var id: String { rawValue }
    var title: String { self == .browser ? "Browser" : "Computer" }
    var icon: String { self == .browser ? "globe" : "display" }
}

extension ActivityDetail {
    /// The reader's Activity setting, for code that is not a view and so
    /// cannot hold an `@AppStorage` of its own: Live Activities, the widget
    /// writer and Walkie read the same line the Updates pill does.
    static var stored: ActivityDetail {
        ActivityDetail(rawValue: UserDefaults.standard.string(forKey: PrefKey.activityDetail) ?? "") ?? .phoneDefault
    }
}
