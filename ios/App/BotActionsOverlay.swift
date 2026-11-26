import CompanionCore
import SwiftUI

/// The long-press surface for a bot: the conversation preview, then its
/// actions in a panel that always sits against the leading edge.
struct BotActionsOverlay: View {
    let bot: Bot
    let chat: Chat
    let threads: [BotTask]
    @ObservedObject var session: Session
    let onOpen: () -> Void
    let onOpenThread: (Chat) -> Void
    let onPin: () -> Void
    let onSettings: () -> Void
    let onNewThread: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.black.opacity(0.32))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 12) {
                ConversationPreviewView(bot: bot, session: session, onOpen: onOpen, height: 440)
                menu
                    .frame(width: 300, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.scale(scale: 0.97).combined(with: .opacity))
        }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !threads.isEmpty {
                Text("Threads")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                ForEach(threads, id: \.threadId) { task in
                    row(task.displayTitle) {
                        if let projected = bot.projected(forThread: task.threadId) {
                            onOpenThread(.bot(projected))
                        }
                    }
                }

                Divider().padding(.vertical, 4)
            }

            row(bot.pinned == true ? "Unpin" : "Pin", icon: bot.pinned == true ? "pin.slash" : "pin", action: onPin)
            row("Bot settings", icon: "gearshape", action: onSettings)
            row("New thread", icon: "plus", action: onNewThread)

            Divider().padding(.vertical, 4)

            row("Delete bot", icon: "trash", destructive: true, action: onDelete)
                .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func row(
        _ title: String,
        icon: String? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 20)
                }
                Text(title)
                    .font(.system(size: 16))
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Color.red : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bot-action.\(title)")
    }
}
