import CompanionCore
import SwiftUI

/// The compact thread label shared by the roster and the thread picker.
struct BotThreadRow: View {
    let task: BotTask
    var selected = false
    /// The thread is holding a queued send, from the client's queue state.
    /// The harness reports this out-of-band; the activity string never says
    /// it, so the row derives it here rather than parsing activity.
    var queued = false

    private var runtime: (title: String, icon: String, color: Color)? {
        // Ordered as the desktop orders its row: the person first, then a
        // teammate wait as a quiet clock (never a spinner), then work.
        if task.activity == "waiting-on-you" { return ("Waiting on you", "hand.raised.fill", .orange) }
        if task.isWaitingOnTeammate { return ("Waiting on teammate", "clock", .secondary) }
        if task.isWorking { return ("Working", "arrow.triangle.2.circlepath", .accentColor) }
        // The queued flag is client state the harness reports out-of-band.
        if task.activity == "queued" || queued { return ("Queued", "clock", .secondary) }
        return nil
    }

    /// A closed or archived thread with nothing live in it reads quieter,
    /// like the desktop's dimmed row; a live status or unread outranks both.
    private var dimmed: Bool {
        (task.isClosed || task.isArchived) && runtime == nil && task.unread != true
    }

    /// One tight two-line row, for the threads under a bot on Home.
    var dense = false

    var body: some View {
        if dense { denseBody } else { regularBody }
    }

    /// Title, then one line of status beside it and the date at the right.
    /// The picker keeps the roomier `regularBody`; Home's opened threads are
    /// there to scan, so they give up a line.
    private var denseBody: some View {
        HStack(spacing: 8) {
            Text(verbatim: task.displayTitle)
                .font(.system(size: 15, weight: task.unread == true ? .semibold : .regular))
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if let runtime {
                Label(runtime.title, systemImage: runtime.icon)
                    .font(.caption2)
                    .foregroundStyle(runtime.color)
                    .fixedSize()
            }
            if task.unread == true {
                Label("Unread", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
            }
            if task.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .accessibilityLabel("Pinned")
            }

            Spacer(minLength: 4)

            if task.listStamp > 0 {
                Text(RelativeStamp.list(task.listStamp))
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .fixedSize()
            }

            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(task.isArchived ? "Archived" : dimmed ? "Closed" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var regularBody: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: task.displayTitle)
                    .font(.body.weight(task.unread == true ? .semibold : .regular))
                    .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                    .lineLimit(2)

                if runtime != nil || task.unread == true {
                    HStack(spacing: 10) {
                        if let runtime {
                            Label(runtime.title, systemImage: runtime.icon)
                                .foregroundStyle(runtime.color)
                        }
                        if task.unread == true {
                            Label("Unread", systemImage: "circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .font(.caption.weight(.medium))
                }

                HStack(spacing: 5) {
                    if task.listStamp > 0 {
                        Text(ThreadStamp.updated(task.listStamp))
                    }
                    if task.pinned == true {
                        if task.listStamp > 0 { Text("·") }
                        Image(systemName: "pin.fill")
                            .accessibilityLabel("Pinned")
                    }
                    if let byline = task.bylineLabel {
                        if task.listStamp > 0 || task.pinned == true { Text("·") }
                        Text(verbatim: byline)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(task.isArchived ? "Archived" : dimmed ? "Closed" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
