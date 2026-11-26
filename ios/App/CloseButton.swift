import SwiftUI

/// The standard top-left dismissal control: a bare X, the way a pushed or
/// presented page closes on iOS.
struct CloseButton: View {
    var action: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(action: (() -> Void)? = nil) {
        self.action = action
    }

    var body: some View {
        Button {
            if let action { action() } else { dismiss() }
        } label: {
            Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
    }
}
