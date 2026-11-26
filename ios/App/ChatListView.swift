// The roster.
//
// Messages-shaped: a glass header, built-in and user-named sidebar sections,
// and a floating bar that keeps Updates, search, organization and new-bot
// actions within one thumb's reach while everything scrolls beneath the
// glass. Two densities, chosen in Settings: compact (the default) puts each
// bot and group on one line; comfortable keeps channels as tiles and bots as
// two-line rows with a "Threads" disclosure beneath each.
import SwiftUI
import CompanionCore
import UIKit

struct ChatListView: View {
    @EnvironmentObject private var session: Session
    @State private var query = ""
    @AppStorage(PrefKey.activityDetail) private var activityDetail = ActivityDetail.phoneDefault.rawValue
    /// Driven so that making a bot can open it. Value-based navigation alone
    /// cannot push without a tap, and a new bot appearing silently at the
    /// bottom of the roster is a poor answer to pressing +.
    @State private var path = NavigationPath()
    @State private var searchHits: [SearchHit] = []
    @AppStorage(PrefKey.updatesPill) private var updatesPill = false
#if DEBUG
    @State private var showingGlassGallery = ProcessInfo.processInfo.arguments.contains("-glass-gallery")
#endif
    @State private var searching = false
    @State private var searchOpen = false
    @State private var showingUpdates = false
    @State private var showingCalendar = false
    @State private var showingSettings = false
    @State private var showingWalkie = false
    @State private var showingNewGroup = false
    @State private var showingNewSection = false
    @State private var expandedBots = Set<String>()
    @State private var collapsedFolders = Set<String>()
    @State private var creatingThreads = Set<String>()
    @State private var managingThreads: Chat?
    @State private var botPendingDeletion: Bot?
    @State private var profileBot: Bot?
    /// The preview lines comfortable rows and search show, folded again only
    /// for a thread that changed. Filled while rendering: it is a cache,
    /// not something any view observes.
    @State private var previewCache = RosterPreviewCache()
    /// Working bots' faces in comfortable rows: six move at once.
    @State private var motionBudget = MascotMotionBudget(limit: 6)
    @FocusState private var searchFocused: Bool

    /// Space between the header's glass buttons and whatever the list
    /// starts with, so a first section title is never tucked under them.
    private static let listTopInset: CGFloat = 12
    /// Clear space above the floating bar once the list is scrolled to its
    /// end. The bar's own height is inset by `safeAreaInset`, so the last
    /// row stays fully visible and tappable whatever the bar measures.
    private static let listBottomMargin: CGFloat = 16

    var body: some View {
        // Read once per render. The island, the pill (twice: the bar lays
        // out both of its widths) and every row's waiting hand all start
        // from the same approvals, and each walk of them visits every thread.
        let approvals = session.state.pendingApprovals
        let updates = session.state.updates(detail: activity, pendingApprovals: approvals)
        let waiting = waitingChats(approvals)
        // Search's matches: the list and its empty state both read them.
        let matches: [ChatSummary] = query.isEmpty ? [] : chats
        NavigationStack(path: $path) {
            GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if query.isEmpty {
                            rosterSections(waiting: waiting)
                        } else {
                            if !searchHits.isEmpty {
                                HStack {
                                    sectionLabel(Text("Messages"))
                                    Spacer()
                                    if searching { ProgressView().controlSize(.small) }
                                }
                                .padding(.top, 10)
                                .padding(.bottom, 4)

                                ForEach(searchHits) { hit in
                                    Button {
                                        Task {
                                            if let chat = await session.open(hit) {
                                                Haptics.selection()
                                                path.append(chat)
                                            }
                                        }
                                    } label: {
                                        SearchHitRow(hit: hit)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 16)
                                }
                                sectionLabel(Text("Threads"))
                                    .padding(.top, 14)
                                    .padding(.bottom, 4)
                            } else if searching {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 24)
                            }

                            botRows(matches, waiting: waiting)
                        }
                    }
                    .padding(.top, Self.listTopInset)
                    .padding(.bottom, Self.listBottomMargin)
                }
                .environment(\.mascotMotionBudget, motionBudget)
                // The roster now runs under the header and gets iOS 26's
                // soft edge effect, the same blend the chat transcript has.
                .softTopScrollEdgeEffect()
                .softBottomScrollEdgeEffect()
                .accessibilityIdentifier("roster-list")
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        header
                        StatusBanner()
                        LiveCallBanner { target in
                            if let bot = session.state.bot(target.botId)?.projected(forThread: target.threadId) {
                                path.append(Chat.bot(bot))
                            }
                        }
                    }
                    .background(rosterHeaderBackground)
                }
                .overlay {
                    if rosterIsEmpty(matches: matches) {
                        if query.isEmpty, session.status == .connecting {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Connecting")
                        } else if query.isEmpty, case .offline = session.status {
                            VStack(spacing: 10) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 24, weight: .regular))
                                    .foregroundStyle(.red)
                                Text("Failed to connect")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                        } else {
                            EmptyStateView(
                                query.isEmpty ? "No bots yet" : "Nothing matches",
                                systemImage: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                                description: Text(
                                    query.isEmpty
                                        ? "Bots you create on your computer show up here."
                                        : "No thread matches \u{201C}\(query)\u{201D}."
                                )
                            )
                        }
                    }
                }
                // The list scrolls beneath the floating bar, and its end is
                // inset by the bar's measured height rather than a guess.
                // On iOS 26 the bar is a safe area bar so the content under
                // it gets the system's soft scroll edge effect.
                .rosterBottomBar(visible: searchOpen || updatesPill) { bottomBar(updates: updates) }
            }
            // top-aligned: the roster fills downward from the header
            .frame(maxWidth: CompanionLayout.rosterWidth, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.appBackground.ignoresSafeArea())
            // a bot that stopped for you grows out of the island
            .overlay(alignment: .top) {
                if CompanionLayout.supportsIslandPresentation {
                    NeedsYouIsland(update: updates.first { $0.kind == .needsYou }) { chat in path.append(chat) }
                }
            }
            }
            .toolbar(.hidden, for: .navigationBar)
#if DEBUG
            .fullScreenCover(isPresented: $showingGlassGallery) {
                if #available(iOS 26.0, *) {
                    GlassGalleryView()
                } else {
                    EmptyView()
                }
            }
#endif
            .navigationDestination(for: Chat.self) { ChatView(chat: $0) }
            .confirmationDialog(
                Text(botPendingDeletion.map { "Delete \($0.name)?" } ?? "Delete bot?"),
                isPresented: Binding(
                    get: { botPendingDeletion != nil },
                    set: { if !$0 { botPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete bot", role: .destructive) {
                    guard let bot = botPendingDeletion else { return }
                    botPendingDeletion = nil
                    Task { await session.deleteBot(bot) }
                }
                Button("Cancel", role: .cancel) { botPendingDeletion = nil }
            } message: {
                Text("This removes the bot and its threads from your computer.")
            }
            .onValueChange(of: session.notificationChat) { chat in
                guard let chat else { return }
                path.append(chat)
                session.consumeNotificationChat()
            }
            .onValueChange(of: session.pendingChat) { chat in
                guard let chat else { return }
                path.append(chat)
                session.consumePendingChat()
            }
            .task {
                if let chat = session.notificationChat {
                    path.append(chat)
                    session.consumeNotificationChat()
                }
                if let chat = session.pendingChat {
                    path.append(chat)
                    session.consumePendingChat()
                }
            }
#if DEBUG
            // Preview-only routes let the screenshot harness reach screens
            // that normally require a paired computer and a tap.
            .task {
                if ProcessInfo.processInfo.arguments.contains("-open-new-section") {
                    showingNewSection = true
                }
                if ProcessInfo.processInfo.arguments.contains("-open-walkie") {
                    showingWalkie = true
                }
                if ProcessInfo.processInfo.arguments.contains("-open-settings") {
                    showingSettings = true
                }
                if ProcessInfo.processInfo.arguments.contains("-open-first"),
                   path.isEmpty, let first = chats.first {
                    path.append(first.chat)
                }
                // Timing-sensitive UI tests start on Gmail directly instead
                // of walking the roster menu.
                if ProcessInfo.processInfo.arguments.contains("-open-preview-gmail"),
                   let bot = session.state.bot(forThread: "preview-gmail") {
                    path.append(Chat.bot(bot))
                }
            }
#endif
            .navigationDestination(
                isPresented: Binding(
                    get: { profileBot != nil },
                    set: { if !$0 { profileBot = nil } }
                )
            ) {
                if let bot = profileBot {
                    AgentProfileView(bot: bot)
                }
            }
            .sheet(isPresented: $showingCalendar) {
                RoutineCalendarView()
                    .environmentObject(session)
            }
            // A full-screen cover keeps the bottom-up opening motion but
            // covers the whole screen; the close control lives top left.
            .fullScreenCover(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    showingSettings = false
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .accessibilityLabel("Close")
                            }
                        }
                }
            }
            .sheet(isPresented: $showingUpdates) {
                UpdatesSheet { chat in
                    showingUpdates = false
                    path.append(chat)
                }
            }
            .fullScreenCover(isPresented: $showingWalkie) {
                WalkieView { chat in
                    showingWalkie = false
                    path.append(chat)
                }
                .environmentObject(session)
            }
            .sheet(isPresented: $showingNewGroup) {
                NewGroupSheet { room in
                    showingNewGroup = false
                    path.append(Chat.room(room))
                }
            }
            .sheet(isPresented: $showingNewSection) {
                NewSectionSheet()
            }
            .sheet(item: $managingThreads) { chat in
                TaskManagerView(chat: chat) { threadId in
                    guard let bot = session.state.bot(forThread: threadId) else { return }
                    managingThreads = nil
                    path.append(Chat.bot(bot))
                }
            }
            .task(id: query) {
                let expected = query
                guard expected.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
                    searchHits = []
                    searching = false
                    return
                }
                searching = true
                defer {
                    if query == expected { searching = false }
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, query == expected else { return }
                let hits = await session.search(expected)
                guard !Task.isCancelled, query == expected else { return }
                searchHits = hits
            }
        }
    }

    // MARK: - Header

    /// Account on the left, search and create on the right — one row of the
    /// same round glass controls, no wordmark above it.
    private var header: some View {
        HStack(alignment: .center) {
            accountButton

            Spacer(minLength: 8)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    Haptics.selection()
                    searchOpen = true
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .glassCapsule()
                .accessibilityLabel("Search")

                if session.canAdminister {
                    Menu {
                        Button("New bot", systemImage: "square.and.pencil", action: createBot)
                        Button("New section", systemImage: "folder.badge.plus", action: openNewSection)
                            .disabled(!hasVisibleBots)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .frame(width: 44, height: 44)
                    }
                    .glassCapsule()
                    .accessibilityLabel("Create")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    /// iOS 26 supplies the blur at the top edge; older systems need an opaque
    /// strip so the roster does not run visibly under the header.
    @ViewBuilder
    private var rosterHeaderBackground: some View {
        if #available(iOS 26.0, *) {
            Color.clear
        } else {
            Color.appBackground
        }
    }

    // MARK: - Sidebar sections

    /// Whether Home opens with the cross-bot "Needs attention" inbox.
    /// Hidden for now: the Updates pill at the bottom already says who needs
    /// the person, and two copies read as two different lists.
    private static let showsAttentionInbox = false

    /// Every thread across every bot that needs the person right now — the
    /// same rule and order as the thread tree, so the inbox can never
    /// disagree with it.
    private var attention: [AttentionThread] {
        crossBotAttentionThreads(session.state.bots)
    }

    @ViewBuilder
    private func rosterSections(waiting: Set<String>) -> some View {
        // Only comfortable rows show a preview line (search, which matches
        // on it, reads `chats` instead).
        let allSummaries = rosterSummaries(previews: density == .comfortable)
        let attention = self.attention
        if Self.showsAttentionInbox, !attention.isEmpty {
            sectionLabel(Text("Needs attention"))
                .padding(.top, 2)
                .padding(.bottom, 4)
            ForEach(attention) { entry in
                Button {
                    Haptics.selection()
                    openAttention(entry)
                } label: {
                    AttentionRow(entry: entry, followsDynamicType: density == .compact)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }

        switch density {
        case .comfortable:
            comfortableChatList(allSummaries, waiting: waiting)
        case .compact:
            compactSections(allSummaries, waiting: waiting)
        }
    }

    /// Comfortable Home, flat: one row per conversation, bots and groups
    /// drawn the same way, in the order a chat app uses — pinned first, then
    /// the most recently active. The threads inside a bot are reached from
    /// its chat header, so there are no section titles and no disclosure.
    private func comfortableChatList(_ allSummaries: [ChatSummary], waiting: Set<String>) -> some View {
        let rows = allSummaries
            // A bot's DM room is the same conversation as its bot row, so
            // only real groups join the flat list.
            .filter { summary in
                switch summary.chat {
                case .bot: return true
                case let .room(room): return room.dm != true
                }
            }
            .sorted { left, right in
                if left.pinned != right.pinned { return left.pinned }
                return left.lastActivity > right.lastActivity
            }
        let pinned = rows.filter { summary in
            if case let .bot(bot) = summary.chat { return bot.pinned == true }
            return false
        }
        let rest = rows.filter { summary in
            if case let .bot(bot) = summary.chat { return bot.pinned != true }
            return true
        }
        return VStack(spacing: 0) {
            if !pinned.isEmpty { pinnedStrip(pinned) }
            comfortableRows(rest, waiting: waiting)
        }
    }

    /// Pinned bots sit above the list as large faces with their names under
    /// them, the way a favourites row reads. The list below omits them.
    private func pinnedStrip(_ pinned: [ChatSummary]) -> some View {
        let rows = stride(from: 0, to: pinned.count, by: 3).map {
            Array(pinned[$0..<min($0 + 3, pinned.count)])
        }
        return VStack(spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(row) { summary in
                        if case let .bot(bot) = summary.chat {
                            Button {
                                path.append(session.threadSelection.restoringThread(
                                    summary.chat, connectionID: session.connection?.id
                                ))
                            } label: {
                                VStack(spacing: 8) {
                                    ChatAvatarView(
                                        chat: summary.chat,
                                        size: 92,
                                        state: MausState.forChat(summary.chat, in: session.state),
                                        animated: false
                                    )
                                    Text(summary.chat.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                                .frame(width: 104)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { rosterMenu(for: bot) } preview: {
                                ConversationPreviewView(bot: bot, session: session)
                            }
                            .accessibilityIdentifier("chat-row.\(summary.chat.id)")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    /// Compact Home keeps the desktop's sections: pinned, groups, bots and
    /// folders still read as groups. The attention inbox is shared by both
    /// densities and hidden at its flag above.
    @ViewBuilder
    private func compactSections(_ allSummaries: [ChatSummary], waiting: Set<String>) -> some View {
        let hasAttention = Self.showsAttentionInbox && !attention.isEmpty

        if let chief = session.state.unsectionedChief {
            VStack(alignment: .leading, spacing: 0) {
                botRows(summaries(for: [chief], from: allSummaries), waiting: waiting)
            }
            // In compact, a one-line row right under the attention rows
            // would read as one more of them: set it apart like a section.
            .padding(.top, hasAttention ? sectionSpacing : 0)
        }

        let pinned = summaries(for: session.state.pinnedBots, from: allSummaries)
        if !pinned.isEmpty {
            sectionLabel(Text("Pinned"))
                .padding(.top, sectionSpacing)
                .padding(.bottom, 4)
            botRows(pinned, waiting: waiting)
        }

        compactRoomsSection(
            title: "Groups",
            rooms: session.state.unsectionedChannels,
            showsCreate: true,
            waiting: waiting
        )

        if !session.state.botChats.isEmpty {
            compactRoomsSection(title: "Bot threads", rooms: session.state.botChats, showsCreate: false, waiting: waiting)
        }

        let unsectioned = summaries(for: session.state.unsectionedBots, from: allSummaries)
        if !unsectioned.isEmpty {
            sectionLabel(Text("Bots"))
                .padding(.top, sectionSpacing)
                .padding(.bottom, 4)
            botRows(unsectioned, waiting: waiting)
        }

        ForEach(session.state.sidebarSections) { section in
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel(Text(verbatim: section.name))
                    .padding(.top, sectionSpacing)
                    .padding(.bottom, 4)
                if !section.chiefs.isEmpty {
                    botRows(summaries(for: section.chiefs, from: allSummaries), waiting: waiting)
                }
                compactRoomRows(section.channels, waiting: waiting)
                botRows(summaries(for: section.bots, from: allSummaries), waiting: waiting)
            }
        }
    }

    /// Between one section and the next title.
    private var sectionSpacing: CGFloat { density == .compact ? 14 : 18 }

    /// Groups as one-line rows under a title that carries the "+" the
    /// comfortable strip shows as a tile.
    @ViewBuilder
    private func compactRoomsSection(
        title: LocalizedStringKey, rooms: [Room], showsCreate: Bool, waiting: Set<String>
    ) -> some View {
        HStack(spacing: 0) {
            sectionLabel(Text(title))
            Spacer(minLength: 0)
            if showsCreate {
                Button {
                    Haptics.selection()
                    showingNewGroup = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .accessibilityLabel("New group")
                .accessibilityIdentifier("new-group")
            }
        }
        // the "+" grows with its title, and stops where the title does
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        // the "+" is a 44pt target; the title keeps the other titles' rhythm
        .frame(minHeight: showsCreate ? 44 : nil)
        .padding(.top, showsCreate ? 0 : sectionSpacing)
        .padding(.bottom, showsCreate ? 0 : 4)
        compactRoomRows(rooms, waiting: waiting)
    }

    /// In the order the tiles showed them, each stamped with its thread's
    /// last message the way `chatSummaries` stamps a row.
    private func compactRoomRows(_ rooms: [Room], waiting: Set<String>) -> some View {
        let today = RosterDay.today
        return ForEach(rooms) { room in
            NavigationLink(value: Chat.room(room)) {
                CompactRoomRow(
                    room: room,
                    members: members(of: room),
                    lastActivity: session.state.lastVisibleMessage(forThread: room.threadId)?.at ?? 0,
                    today: today,
                    waiting: waiting.contains(room.id)
                )
                .equatable()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-row.\(room.id)")
        }
    }

    private func channelsStrip(title: LocalizedStringKey, rooms: [Room], showsCreate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(Text(title))
            channelTiles(rooms, showsCreate: showsCreate)
        }
        .padding(.top, 2)
    }

    private func channelTiles(_ rooms: [Room], showsCreate: Bool) -> some View {
        // Members travel in the data, as the comfortable rows' values do.
        let tiles = rooms.map { RoomTile(room: $0, members: members(of: $0)) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tiles) { tile in
                    NavigationLink(value: Chat.room(tile.room)) {
                        GroupTile(room: tile.room, members: tile.members)
                            .equatable()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat-row.\(tile.id)")
                }
                if showsCreate {
                    Button {
                        Haptics.selection()
                        showingNewGroup = true
                    } label: {
                        GroupTile(room: nil, members: [])
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New group")
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func botRows(_ rows: [ChatSummary], waiting: Set<String>) -> some View {
        switch density {
        case .comfortable: comfortableRows(rows, waiting: waiting)
        case .compact: compactRows(rows, waiting: waiting)
        }
    }

    /// One line per bot, its threads beneath it once opened. Search results
    /// can include groups, which get their own one-line row.
    private func compactRows(_ rows: [ChatSummary], waiting: Set<String>) -> some View {
        let queued = session.state.queuedThreadIds
        let today = RosterDay.today
        return ForEach(rows) { summary in
            switch summary.chat {
            case let .bot(bot):
                CompactBotEntry(
                    bot: bot,
                    face: MausState.forChat(summary.chat, in: session.state),
                    lastActivity: summary.lastActivity,
                    today: today,
                    hasPendingCard: waiting.contains(bot.id),
                    queuedThreadIds: queued,
                    query: query,
                    expanded: expandedBots.contains(bot.id),
                    collapsedFolders: collapsedFolders,
                    creating: creatingThreads.contains(bot.id),
                    session: session,
                    toggleExpanded: {
                        if expandedBots.contains(bot.id) { expandedBots.remove(bot.id) } else { expandedBots.insert(bot.id) }
                    },
                    collapse: { expandedBots.remove(bot.id) },
                    toggleFolder: { key in
                        if collapsedFolders.contains(key) { collapsedFolders.remove(key) } else { collapsedFolders.insert(key) }
                    },
                    beginCreating: { creatingThreads.insert(bot.id).inserted },
                    endCreating: { creatingThreads.remove(bot.id) },
                    openRow: {
                        path.append(session.threadSelection.restoringThread(summary.chat, connectionID: session.connection?.id))
                    },
                    open: { chat in path.append(chat) },
                    manage: { chat in managingThreads = chat }
                )
                .equatable()
            case let .room(room):
                Button {
                    path.append(summary.chat)
                } label: {
                    CompactRoomRow(
                        room: room, members: members(of: room),
                        lastActivity: summary.lastActivity, today: today, waiting: waiting.contains(room.id)
                    )
                    .equatable()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-row.\(room.id)")
            }
        }
    }

    /// Two lines per chat. A bot's down chevron at the end of the preview
    /// line opens its threads in place; a running search opens the matching
    /// threads on its own, since the search is what produced the row.
    private func comfortableRows(_ rows: [ChatSummary], waiting: Set<String>) -> some View {
        // A new search is a new list: give the ForEach a new identity so a
        // row kept from the previous branch (Home's full roster) is rebuilt
        // with this search's values instead of reused with the old ones.
        let searchKey = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return ForEach(comfortableEntries(rows, waiting: waiting)) { entry in
            VStack(spacing: 0) {
                Button {
                    openRosterRow(entry)
                } label: {
                    entry.row.equatable()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-row.\(entry.id)")
                .contextMenu {
                    if case let .bot(bot) = entry.row.chat {
                        rosterMenu(for: bot)
                    }
                } preview: {
                    if case let .bot(bot) = entry.row.chat {
                        ConversationPreviewView(bot: bot, session: session)
                    } else {
                        entry.row
                            .padding(.vertical, 2)
                            .background(
                                Color.appBackground,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                            )
                    }
                }

                if !entry.searchQuery.isEmpty,
                   case let .bot(bot) = entry.row.chat {
                    threadTree(
                        bot,
                        showsNewThread: entry.searchQuery.isEmpty,
                        queued: entry.queued,
                        held: entry.held
                    )
                }
            }
            // Keep a row's identity tied to the search it was built under, so
            // the lazy list cannot hand back the pre-search row. Expansion is
            // deliberately not part of it: the row stays put and only the
            // threads below it grow, which is what makes the slide smooth.
            .id("\(entry.id)|\(entry.searchQuery)")
        }
        .id(searchKey)
    }

    /// Each row worked out before the `ForEach`, so everything it shows is
    /// in the `ForEach`'s data: the lazy list may skip rebuilding a row whose
    /// data did not change, and a value read inside the closure instead
    /// would go stale there.
    private func comfortableEntries(_ rows: [ChatSummary], waiting: Set<String>) -> [ComfortableEntry] {
        let state = session.state
        let today = RosterDay.today
        let queued = state.queuedThreadIds
        // The trees' "Queued" marks read the held sends themselves.
        let held = Set(state.pendingQueued.compactMap { $0.value.isEmpty ? nil : $0.key })
        // Read once here, on the render that builds the entries, so the row
        // gets the current search rather than a stale one from its closure.
        let searching = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.enumerated().map { index, summary -> ComfortableEntry in
            let row = ChatRow(
                chat: summary.chat,
                preview: summary.preview,
                at: summary.lastActivity,
                today: today,
                state: MausState.forChat(summary.chat, in: state),
                waiting: waiting.contains(summary.chat.id),
                last: index == rows.count - 1
            )
            return ComfortableEntry(
                row: row,
                queued: queued,
                held: held,
                searchQuery: searching
            )
        }
    }

    private func openRosterRow(_ entry: ComfortableEntry) {
        path.append(session.threadSelection.restoringThread(
            entry.row.chat, connectionID: session.connection?.id
        ))
    }

    /// The native Haptic Touch menu: threads (and starting one) live in a
    /// submenu, the way a system menu expands them in place.
    @ViewBuilder
    private func rosterMenu(for bot: Bot) -> some View {
        let threads = bot.visibleTasks
        Menu {
            ForEach(threads, id: \.threadId) { task in
                Button {
                    Haptics.selection()
                    if let projected = bot.projected(forThread: task.threadId) {
                        path.append(Chat.bot(projected))
                    }
                } label: {
                    Text(task.displayTitle)
                }
            }
            if !threads.isEmpty { Divider() }
            Button {
                Haptics.selection()
                Task {
                    if let created = await session.createRosterThread(for: bot) {
                        path.append(Chat.bot(created))
                    }
                }
            } label: {
                Label("New thread", systemImage: "plus")
            }
        } label: {
            Label("Threads", systemImage: "bubble.left.and.bubble.right")
        }

        Button {
            Haptics.selection()
            Task { await session.setBotPinned(bot, pinned: bot.pinned != true) }
        } label: {
            Label(bot.pinned == true ? "Unpin" : "Pin", systemImage: bot.pinned == true ? "pin.slash" : "pin")
        }
        Button {
            Haptics.selection()
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                profileBot = bot
            }
        } label: {
            Label("Bot settings", systemImage: "gearshape")
        }
        Divider()
        Button(role: .destructive) {
            Haptics.selection()
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                botPendingDeletion = bot
            }
        } label: {
            Label("Delete bot", systemImage: "trash")
        }
    }

    private func botId(_ chat: Chat) -> String {
        if case let .bot(bot) = chat { return bot.id }
        return chat.id
    }

    private func threadTree(
        _ bot: Bot, showsNewThread: Bool, queued: Set<String>, held: Set<String>
    ) -> some View {
        BotThreadTree(
            bot: bot,
            query: $query,
            showsNewThread: showsNewThread,
            creatingThreads: $creatingThreads,
            queuedThreadIds: queued,
            heldThreadIds: held,
            session: session,
            open: { chat in path.append(chat) }
        )
        .equatable()
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private func bottomBar(updates: [ChatUpdate]) -> some View {
        if searchOpen || updatesPill {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                if searchOpen {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.secondary)
                        TextField("Search threads", text: $query)
                            .font(.system(size: 17))
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .focused($searchFocused)
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .glassCapsule()

                    Button("Cancel") {
                        query = ""
                        searchOpen = false
                        searchFocused = false
                    }
                    .font(.system(size: 17))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .glassCapsule()
                } else {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        updatesButton(updates: updates)
                            .frame(width: 250)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.25), value: searchOpen)
        }
    }

    private func updatesButton(updates: [ChatUpdate]) -> some View {
        UpdatesPill(updates: updates) {
            Haptics.selection()
            showingUpdates = true
        }
        .frame(height: 52)
    }

    /// The account menu, top left beside the wordless header: the same round
    /// glass control as search and create.
    private var accountButton: some View {
        Menu {
            if !updatesPill {
                Button { showingUpdates = true } label: {
                    Label("Updates", systemImage: "tray.full")
                }
            }
            Button { showingSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Button { showingCalendar = true } label: {
                Label("Routine calendar", systemImage: "calendar")
            }
        } label: {
            Image(systemName: "person")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .glassCapsule()
        .accessibilityLabel(session.connection.map { LocalizedStringKey("Connected to \($0.name)") }
            ?? "Account")
        .accessibilityHint("Settings and the routine calendar")
        .accessibilityIdentifier("account")
    }

    private var hasVisibleBots: Bool {
        session.state.bots.contains { $0.hidden != true }
    }

    private func openNewSection() {
        Haptics.selection()
        showingNewSection = true
    }

    private func createBot() {
        Task {
            if let bot = await session.createBot() {
                Haptics.success()
                path.append(Chat.bot(bot))
            }
        }
    }

    // MARK: - Data

    /// The reader's activity level, which the roster preview folds by.
    private var activity: ActivityDetail { ActivityDetail(rawValue: activityDetail) ?? .phoneDefault }

    /// The roster is always the comfortable, two-line layout; compact was
    /// removed with its Settings choice.
    private var density: RosterDensity { .comfortable }

    private var chats: [ChatSummary] {
        let all = rosterSummaries(previews: true)
        guard !query.isEmpty else {
            // rooms live in the strip; the list is bots
            return all.filter { if case .bot = $0.chat { return true } else { return false } }
        }
        let queued = session.state.queuedThreadIds
        return all.filter {
            $0.chat.name.localizedCaseInsensitiveContains(query)
                || $0.chat.subtitle.localizedCaseInsensitiveContains(query)
                || $0.preview.localizedCaseInsensitiveContains(query)
                || matchesThread($0.chat, queued: queued)
        }
    }

    private func matchesThread(_ chat: Chat, queued: Set<String>) -> Bool {
        guard case let .bot(bot) = chat else { return false }
        return !bot.threadGroups(matching: query, queuedThreadIds: queued).isEmpty
    }

    /// Every chat in roster order, as `chatSummaries` lists them. With
    /// previews, each line comes from `previewCache`, which folds a thread
    /// again only once it has changed; without, the cache lets go of what
    /// it holds.
    private func rosterSummaries(previews: Bool) -> [ChatSummary] {
        let state = session.state
        let all = state.chatSummaries(activity: activity, previews: false)
        guard previews else {
            previewCache.removeAll()
            return all
        }
        previewCache.keepOnly(Set(all.map(\.chat.threadId)))
        return all.map { summary in
            ChatSummary(
                chat: summary.chat,
                preview: previewCache.preview(forThread: summary.chat.threadId, in: state, detail: activity),
                lastActivity: summary.lastActivity,
                pinned: summary.pinned
            )
        }
    }

    private func openAttention(_ entry: AttentionThread) {
        guard let bot = entry.destinationBot(in: session.state) else { return }
        path.append(Chat.bot(bot))
    }

    private func summaries(for bots: [Bot], from all: [ChatSummary]) -> [ChatSummary] {
        let ids = Set(bots.map(\.id))
        return all.filter { summary in
            if case let .bot(bot) = summary.chat { return ids.contains(bot.id) }
            return false
        }
    }

    private func waitingChats(_ approvals: [(threadId: String, message: Message)]) -> Set<String> {
        Set(approvals.compactMap { session.state.chat(forThread: $0.threadId)?.id })
    }

    private func members(of room: Room) -> [Bot] {
        room.memberIds.compactMap { session.state.bot($0) }
    }

    private func rosterIsEmpty(matches: [ChatSummary]) -> Bool {
        if query.isEmpty {
            return session.state.bots.allSatisfy { $0.hidden == true } && session.state.rooms.isEmpty
        }
        return matches.isEmpty && searchHits.isEmpty && !searching
    }

    private func sectionLabel(_ text: Text) -> some View {
        text
            .textCase(.uppercase)
            // Compact rows follow Dynamic Type, so their titles do too, but
            // only up to xxxLarge: beyond it these uppercase labels would
            // outweigh the names they head. Comfortable's never scale.
            .font(density == .compact ? .footnote.weight(.semibold) : .system(size: 13, weight: .semibold))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .tracking(0.4)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 20)
    }
}

extension View {
    /// Places the floating roster bar. On iOS 26 a safe area bar hands the
    /// system the bottom edge, so the list fades and blurs beneath it; older
    /// systems keep the plain safe-area inset.
    @ViewBuilder
    func rosterBottomBar<Bar: View>(visible: Bool = true, @ViewBuilder bar: () -> Bar) -> some View {
        if visible {
            if #available(iOS 26.0, *) {
                safeAreaBar(edge: .bottom, spacing: 0, content: bar)
            } else {
                safeAreaInset(edge: .bottom, spacing: 0, content: bar)
            }
        } else {
            self
        }
    }
}

// MARK: - Rows and tiles

/// One comfortable row as the list worked it out: the row, and what its
/// thread tree needs beyond the list's own state.
private struct ComfortableEntry: Identifiable, Equatable {
    /// Equatable on everything it draws (the whole bot or room).
    let row: ChatRow
    let queued: Set<String>
    let held: Set<String>
    /// The roster search this entry was built under. Part of the data so a
    /// row re-renders as the query narrows, and so the tree it may show is
    /// filtered by the current text rather than the row's creation time.
    let searchQuery: String

    var id: String { row.chat.id }
}

/// A room and its members as the state holds them, for its tile.
private struct RoomTile: Identifiable, Equatable {
    let room: Room
    let members: [Bot]

    var id: String { room.id }
}

/// A room as a round tile: the first two members' mascots stacked, its name
/// beneath. `nil` is the "make one" tile.
///
/// Its members come from the list, which looks them up once, and it is shown
/// `.equatable()`: a tile no longer redraws its two faces on every publish.
struct GroupTile: View, Equatable {
    let room: Room?
    /// The room's members as the state holds them.
    let members: [Bot]

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                if let room {
                    Circle().fill(Color.secondary.opacity(0.14))
                    let bots = members
                    if let first = bots.first {
                        BotAvatarView(bot: first, size: 34, state: .happy, animated: false)
                            .offset(x: -9, y: -6)
                    }
                    if bots.count > 1 {
                        BotAvatarView(bot: bots[1], size: 30, state: .happy, animated: false)
                            .padding(2)
                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                            .offset(x: 11, y: 9)
                    }
                    if room.unread {
                        Circle()
                            .fill(MausPalette.color("blue"))
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(3)
                    }
                } else {
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.secondary)
                }
            }
            .frame(width: 64, height: 64)

            Text(room?.name ?? "New group")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(room == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
        }
        .frame(width: 76)
        .contentShape(Rectangle())
    }
}

/// One thread that needs the person, from any bot: title, status, and the
/// bot it belongs to, ready to jump straight there. Waiting outranks
/// working, which outranks queued and unread — the same order as the tree.
struct AttentionRow: View {
    let entry: AttentionThread
    /// Compact's rows follow Dynamic Type, and these grow with them, in the
    /// proportions they have at the default size. Comfortable's rows keep
    /// fixed sizes, and so do these beside them.
    var followsDynamicType = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var scaledTitle: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var scaledDetail: CGFloat = 12
    @ScaledMetric(relativeTo: .subheadline) private var scaledMarkWidth: CGFloat = 24

    /// The title's size, and the mark's beside it.
    private var titleSize: CGFloat { followsDynamicType ? scaledTitle : 15 }
    private var detailSize: CGFloat { followsDynamicType ? scaledDetail : 12 }
    private var markWidth: CGFloat { followsDynamicType ? scaledMarkWidth : 24 }
    /// A scaled title wraps at the accessibility sizes instead of being cut
    /// short, as compact's names and thread titles do there.
    private var titleWraps: Bool { followsDynamicType && typeSize.isAccessibilitySize }

    private var waiting: Bool { entry.task.activity == "waiting-on-you" }
    private var working: Bool { !waiting && (entry.task.busy == true || entry.task.activity == "working") }
    private var queued: Bool { !waiting && !working && entry.task.activity == "queued" }

    private var statusText: String {
        if waiting { return "Waiting on you" }
        if working { return "Working" }
        if queued { return "Queued" }
        return "Unread"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: waiting ? "exclamationmark.circle.fill" : queued ? "clock" : "bell.badge.fill")
                        .font(.system(size: titleSize, weight: .medium))
                }
            }
            .foregroundStyle(waiting ? Color.orange : queued ? Color.secondary : Color.accentColor)
            .frame(width: markWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.task.displayTitle)
                    .font(.system(size: titleSize, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(titleWraps ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: titleWraps)
                Text("\(entry.botName) · \(statusText)")
                    .font(.system(size: detailSize))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.task.displayTitle), \(entry.botName), \(statusText)")
    }
}

/// A bot or group in comfortable Home: face, name and role, time, the last
/// line, and a hand while it waits on the person.
///
/// Plain values only, shown `.equatable()` like `CompactBotEntry`, so a row
/// whose chat has not moved is skipped when the session publishes.
struct ChatRow: View, Equatable {
    let chat: Chat
    let preview: String
    let at: Double
    /// The day the list drew on (`RosterDay.today`); see
    /// `CompactBotEntry.today`. "9:15 AM" must still become "Yesterday".
    let today: Date
    var state: MausState = .idle
    var waiting = false
    var last = false

    /// `Chat`'s own `==` compares identity (id and thread) only; a row
    /// draws the whole bot or room, so it compares those.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.preview == rhs.preview && lhs.at == rhs.at && lhs.today == rhs.today && lhs.state == rhs.state
            && lhs.waiting == rhs.waiting && lhs.last == rhs.last
            && sameContent(lhs.chat, rhs.chat)
    }

    private static func sameContent(_ lhs: Chat, _ rhs: Chat) -> Bool {
        switch (lhs, rhs) {
        case let (.bot(left), .bot(right)): return left == right
        case let (.room(left), .room(right)): return left == right
        default: return false
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // the unread dot, in the bot's own colour, at the very edge
            ZStack {
                if chat.unread && !chat.busy {
                    Circle()
                        .fill(MausPalette.color(chat.color))
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 18)
            .frame(maxHeight: .infinity)

            HStack(alignment: .top, spacing: 10) {
                ChatAvatarView(chat: chat, size: 52, state: state, animated: state.showsActivity)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(chat.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        // the bot's job, the way the desktop shows it
                        if !chat.subtitle.isEmpty {
                            Text(chat.subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }

                        Spacer(minLength: 4)

                        Text(RelativeStamp.list(at))
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .fixedSize()
                    }

                    HStack(alignment: .center, spacing: 6) {
                        // one line for every bot, so the rows keep one rhythm
                        Text(preview.isEmpty ? " " : preview)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if chat.busy {
                            ProgressView().controlSize(.mini)
                        }
                    }

                    if waiting {
                        Label("Waiting on you", systemImage: "hand.raised.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(MausPalette.color(chat.color)))
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if !last { Divider() }
                }
            }
            .padding(.trailing, 16)
        }
        .padding(.leading, 4)
        .contentShape(Rectangle())
    }
}

/// The floating pill: who is doing what right now, at a glance.
struct UpdatesPill: View {
    let updates: [ChatUpdate]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !updates.isEmpty {
                    MascotStack(colors: Array(updates.prefix(3).map(\.chat.color)))
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if let first = updates.first {
                            switch first.kind {
                            case .needsYou:
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(MausPalette.color(first.chat.color))
                                Text("\(first.chat.name) needs you")
                            case .working:
                                Text("\(first.chat.name) is working")
                            case .toReview:
                                Text("\(first.chat.name) has an update")
                            }
                        } else {
                            Text("All quiet")
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(updates.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    // The bar is deliberately narrow; shrink a long bot name
                    // rather than cutting the sentence to "…".
                    .minimumScaleFactor(0.85)

                    Text(subline)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.leading, updates.isEmpty ? 16 : 7)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .accessibilityLabel("Updates")
        .accessibilityIdentifier("updates-button")
    }

    private var subline: String {
        guard let first = updates.first else { return "Nothing needs you" }
        let rest = updates.count - 1
        if rest == 0 { return first.line.isEmpty ? " " : first.line }
        return rest == 1 ? "1 more update" : "\(rest) more updates"
    }
}

/// Up to three mascots overlapping, the way a group of faces reads at a glance.
struct MascotStack: View {
    let colors: [String]
    var size: CGFloat = 28
    var overlap: CGFloat = 12

    var body: some View {
        HStack(spacing: -overlap) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                MausAvatar(color: color, size: size, state: .idle, animated: false)
                    .padding(2)
            }
        }
    }
}

/// Connection state, shown only when it is not "fine".
struct StatusBanner: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        stateBanner
            .animation(.default, value: session.status)
    }

    @ViewBuilder
    private var stateBanner: some View {
        switch session.status {
        case .live, .unpaired:
            EmptyView()
        case .connecting:
            // The roster header carries this as a small inline spinner and
            // label; a full-width banner would say the same thing louder.
            EmptyView()
        case .offline:
            // The empty roster shows one small failure mark in the middle;
            // the banner would say the same thing louder.
            EmptyView()
        case .unauthorized:
            banner("This device was unpaired on the computer.", systemImage: "lock.slash", tint: .red)
        }
    }

    private func banner(
        _ text: String, systemImage: String, tint: Color, canRetry: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.16)))

            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if canRetry {
                    Button("Try again") {
                        Task { await session.refresh() }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: hit.role == .user ? "person.fill" : "bubble.left.fill")
                .foregroundStyle(Color.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.secondary.opacity(0.13)))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(hit.name).font(.system(size: 15, weight: .semibold))
                    if let task = hit.task, !task.isEmpty {
                        Text(task).font(.system(size: 12)).foregroundStyle(Color.secondary)
                    }
                    Spacer()
                    Text(RelativeStamp.list(hit.at))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                }
                Text(hit.snippet)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// Timestamps the way a messaging app writes them.
enum RelativeStamp {
    /// Roster: time today, weekday this week, date beyond that.
    static func list(_ at: Double) -> String {
        guard at > 0 else { return "" }
        let date = Date(timeIntervalSince1970: at / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let week = calendar.date(byAdding: .day, value: -6, to: Date()), date > week {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// In a transcript: enough to place a gap in the conversation.
    static func separator(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }
}
