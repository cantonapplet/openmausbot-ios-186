// The reduced transcript's activity: a short, quiet list of the steps a bot
// has taken and the one it is on, newest at the bottom.
import SwiftUI
import CompanionCore

struct ActivityRunChip: View {
    let items: [Message]

    /// The image keeps this glanceable: the last few steps, never the whole
    /// tool history.
    private var steps: [Message] { Array(items.suffix(4)) }

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(steps, id: \.id) { item in
                    HStack(spacing: 8) {
                        glyph(item.tool?.ok)
                        Text(item.tool?.displayLabel ?? "Working")
                            .font(.system(size: 14))
                            .foregroundStyle(item.tool?.ok == nil ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                BubbleColor.theirs,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .padding(.trailing, 44)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func glyph(_ ok: Bool?) -> some View {
        switch ok {
        case .some(true):
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
        case .some(false):
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 12)
        case .none:
            Circle()
                .fill(Color.secondary)
                .frame(width: 6, height: 6)
                .frame(width: 12)
        }
    }
}


extension ToolActivity {
    /// What the monitor says, in a phrase rather than the computer's tool
    /// name. The computer's own spoken phrase wins when it has one.
    var displayLabel: String {
        let text = rawDisplayLabel
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private var rawDisplayLabel: String {
        if let spoken, !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return spoken
        }
        if let cause = failedTurnCause(name) { return cause }
        if name.hasPrefix("notice:") {
            return String(name.dropFirst("notice:".count)).trimmingCharacters(in: .whitespaces)
        }
        switch name.lowercased() {
        case "execute", "bash", "shell", "run_command", "command", "terminal":
            return "Running a command"
        case "read", "read_file", "open_file", "view_file":
            return "Reading a file"
        case "write", "write_file", "create_file":
            return "Writing a file"
        case "edit", "edit_file", "apply_patch", "str_replace", "multi_edit":
            return "Editing a file"
        case "grep", "search", "search_files", "find":
            return "Searching files"
        case "glob", "list_files", "ls":
            return "Listing files"
        case "web_search", "search_web", "websearch":
            return "Searching the web"
        case "web_fetch", "fetch", "open_url", "browse_url":
            return "Reading a webpage"
        case "browser":
            return "Using the browser"
        case "screenshot":
            return "Taking a screenshot"
        case "memory_update", "memory":
            return "Updating memory"
        case "attach_file", "attach":
            return "Attaching a file"
        case "send_message", "message":
            return "Sending a message"
        case "composio", "composio_search", "connect":
            return "Searching connected apps"
        case "task", "spawn_agent", "agent", "delegate":
            return "Starting a helper"
        case "skill", "skill_execution":
            return "Running a skill"
        default:
            let humanised = name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard let first = humanised.first else { return "Working" }
            return first.uppercased() + humanised.dropFirst()
        }
    }
}
