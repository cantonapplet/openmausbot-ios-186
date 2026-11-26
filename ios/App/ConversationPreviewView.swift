import CompanionCore
import SwiftUI

/// The Haptic Touch preview of a bot's conversation: who it is, and the last
/// things that were said, anchored to the bottom the way an open chat reads.
/// A snapshot, not a second chat.
struct ConversationPreviewView: View {
    let bot: Bot
    /// Passed in: the preview can live in its own host, away from the
    /// roster's environment objects.
    @ObservedObject var session: Session
    var onOpen: () -> Void = {}
    var height: CGFloat = 520

    private var messages: [Message] {
        Array(
            session.state.visibleTranscript(forThread: bot.threadId)
                .filter { $0.kind == .text && !($0.text ?? "").isEmpty }
                .suffix(10)
        )
    }

    private var context: TranscriptRowContext {
        let connection = session.connection
        return TranscriptRowContext(
            threadId: bot.threadId,
            name: bot.name,
            color: bot.color,
            botId: bot.id,
            busy: bot.busy == true,
            editPending: false,
            claudeInstanceId: bot.currentTaskModelSelection.instanceId,
            credentials: CredentialAccess(
                connectionId: connection?.id,
                pairedForSecrets: connection.map { $0.secretPublicKey != nil && $0.companionDeviceId != nil } ?? false,
                transportProtected: session.phoneCredentialTransportIsProtected,
                status: session.status,
                resetGeneration: session.credentialEntryResetGeneration
            )
        )
    }

    private var actions: TranscriptActions {
        TranscriptActions(threadId: bot.threadId, session: session, router: TranscriptRouter())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages) { message in
                    TextBubble(
                        message: message,
                        presentation: MessagePresentations.of(message),
                        context: context,
                        actions: actions
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .clipped()
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open \(bot.name)")
    }

    private var header: some View {
        HStack(spacing: 12) {
            ChatAvatarView(
                chat: .bot(bot),
                size: 44,
                state: MausState.forBot(bot, last: session.state.lastVisibleMessage(forThread: bot.threadId)),
                animated: false
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(bot.title.isEmpty ? "Bot" : bot.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
