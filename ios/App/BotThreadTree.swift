import CompanionCore
import SwiftUI

/// A bot's threads, opened by the chevron at the end of its Home row.
///
/// The list shows this only when that bot is open (or a search matched one of
/// its threads), so the tree has no header of its own: one flat list of
/// thread rows follows straight on from the bot, with a New thread row at
/// the end. Desktop folders still exist for the sidebar, the compact roster
/// and the thread picker; they do not split this short list.
///
/// It used to observe the whole session and sort the bot's threads twice on
/// every publish, for every bot. It now takes its bot and the queue state as
/// values and is Equatable on them, as `CompactBotEntry` is, so a publish
/// that did not move its bot skips it.
///
/// The list's own state (the search, which bot is making a thread) is read
/// through bindings to that state, as before: the tree follows every
/// keystroke and tap even when the lazy list does not rebuild its row. They
/// are the list's `@State` projections, one stable location each, not
/// per-row `Binding(get:set:)`, which is a new location on every render. The
/// search is compared in `==` below because it changes what the tree shows;
/// the creating binding is left out, since the tree writes it itself and
/// redraws through the binding.
struct BotThreadTree: View, Equatable {
    /// The bot as the state holds it now.
    let bot: Bot
    /// The roster search: a match lists the bot's threads.
    @Binding var query: String
    /// Whether the New thread row belongs here. Search matches do not offer
    /// it: a search is for finding a thread, not making one.
    var showsNewThread = true
    /// Bots a thread is being made for from the list.
    @Binding var creatingThreads: Set<String>
    /// `CompanionState.queuedThreadIds`: held sends keep a closed thread listed.
    let queuedThreadIds: Set<String>
    /// Threads holding at least one held send, for the rows' "Queued".
    let heldThreadIds: Set<String>
    /// For the tree's actions only; a plain reference is not observed.
    let session: Session
    let open: (Chat) -> Void

    /// What the tree draws from values; see the type's note on the bindings.
    ///
    /// `query` is part of this even though it arrives as a binding: the
    /// search decides which threads the tree lists, and that change starts in
    /// the list above. Leaving it out let the equatable wrapper skip the
    /// tree's body, so a flat Home's search matched a bot but never showed
    /// the sibling thread that matched.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bot == rhs.bot && lhs.queuedThreadIds == rhs.queuedThreadIds
            && lhs.heldThreadIds == rhs.heldThreadIds && lhs.session === rhs.session
            && lhs.query == rhs.query && lhs.showsNewThread == rhs.showsNewThread
    }

    /// A timed snooze ends on the wall clock, not on a server ping: bump
    /// this when the nearest expiry passes so its row folds back in without
    /// waiting for the next snapshot. Mirrors the desktop's useSnoozeExpiry.
    @State private var snoozeTick = 0

    private var creating: Bool { creatingThreads.contains(bot.id) }

    var body: some View {
        let _ = snoozeTick
        let matching = bot.name.localizedCaseInsensitiveContains(query) ? "" : query
        // Flattened on purpose: within this short list a folder heading was
        // one more gap to read, and the group boundaries made the row
        // spacing uneven. The order is still the sidebar's.
        let threads = bot.threadGroups(matching: matching, queuedThreadIds: queuedThreadIds)
            .flatMap(\.tasks)
        let nextSnoozeExpiry = bot.visibleTasks.nextSnoozeExpiry()
        VStack(alignment: .leading, spacing: 0) {
            threadLinks(threads)
            if showsNewThread {
                newThreadRow()
            }
            // Close the opened section the way the row's own divider closes
            // each chat above it.
            Divider()
        }
        .padding(.leading, 94)
        .padding(.trailing, 18)
        .snoozeExpiryTick(nextSnoozeExpiry, tick: $snoozeTick)
    }

    private func newThreadRow() -> some View {
        Button { createThread() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("New thread")
                Spacer(minLength: 0)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.primary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(creating)
        .accessibilityIdentifier("new-thread.\(bot.id)")
        .accessibilityLabel("New thread with \(bot.name)")
    }

    private func threadLinks(_ tasks: [BotTask]) -> some View {
        ForEach(tasks, id: \.threadId) { task in
            if let projected = bot.projected(forThread: task.threadId) {
                NavigationLink(value: Chat.bot(projected)) {
                    BotThreadRow(task: task, queued: heldThreadIds.contains(task.threadId), dense: true)
                        .padding(.vertical, 1)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        let pinned = task.pinned != true
                        Task { await session.setTaskPinned(task, pinned: pinned, in: .bot(bot)) }
                    } label: {
                        Label(task.pinned == true ? "Unpin" : "Pin", systemImage: task.pinned == true ? "pin.slash" : "pin")
                    }
                }
                .accessibilityIdentifier("thread.\(task.threadId)")
            }
        }
    }

    private func createThread() {
        guard creatingThreads.insert(bot.id).inserted else { return }
        Task {
            defer { creatingThreads.remove(bot.id) }
            if let created = await session.createRosterThread(for: bot) {
                open(.bot(created))
            }
        }
    }
}

extension Session {
    /// A new thread started from the home list, in either density. A
    /// failure always says something, even when the client had no error.
    func createRosterThread(for bot: Bot) async -> Bot? {
        if let created = await createTask(for: bot, title: nil) { return created }
        if actionError == nil {
            actionError = "Couldn't create a thread. Check the connection and try again."
        }
        return nil
    }
}

extension View {
    /// A timed snooze ends on the wall clock, not on a server ping: bump
    /// `tick` when the nearest expiry passes so a view reading the thread
    /// list folds that thread back in without waiting for the next snapshot.
    /// Mirrors the desktop's useSnoozeExpiry.
    func snoozeExpiryTick(_ nextExpiry: Double?, tick: Binding<Int>) -> some View {
        task(id: "\(nextExpiry ?? 0):\(tick.wrappedValue)") {
            guard let nextExpiry else { return }
            let seconds = max(0, (nextExpiry - Date().timeIntervalSince1970 * 1_000) / 1_000) + 0.05
            // Remote deadlines can be arbitrarily distant. Bound the
            // duration conversion and re-arm with the tick until due.
            try? await Task.sleep(for: .seconds(min(86_400, seconds)))
            guard !Task.isCancelled else { return }
            tick.wrappedValue += 1
        }
    }
}
