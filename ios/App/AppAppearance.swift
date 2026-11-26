import SwiftUI
import UIKit

extension Color {
    /// Page colour: white in light, #141414 in dark.
    static let appBackground = Color("AppBackground")
    /// Grouped-form colour: system grouped grey in light, #141414 in dark.
    static let appGroupedBackground = Color("AppGroupedBackground")
}

/// How the app draws itself: the phone's setting, or a fixed light/dark look.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    init(stored: String) {
        self = AppAppearance(rawValue: stored) ?? .system
    }

    var label: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `.preferredColorScheme(nil)` follows the device.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// UIKit chrome — context menus, alerts and action sheets — follows the
    /// window, not SwiftUI's preferredColorScheme.
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Applies the chosen theme to every window, including the ones UIKit
/// creates for presentation chrome. Context menus and action sheets use a
/// presentation window of their own, which a single window override misses.
@MainActor
final class WindowAppearance {
    static let shared = WindowAppearance()

    private var style: UIUserInterfaceStyle = .unspecified
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply()
                // The presentation window can finish configuring a beat after
                // it becomes visible; one more pass catches it.
                DispatchQueue.main.async { self?.apply() }
            }
        }
    }

    func update(_ style: UIUserInterfaceStyle) {
        self.style = style
        apply()
    }

    private func apply() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) {
            window.overrideUserInterfaceStyle = style
        }
    }
}

struct WindowAppearanceBridge: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> WindowStyleView {
        WindowStyleView(style: style)
    }

    func updateUIView(_ view: WindowStyleView, context: Context) {
        view.style = style
    }
}

final class WindowStyleView: UIView {
    var style: UIUserInterfaceStyle {
        didSet { apply() }
    }

    init(style: UIUserInterfaceStyle) {
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    private func apply() {
        MainActor.assumeIsolated {
            WindowAppearance.shared.update(style)
        }
    }
}
