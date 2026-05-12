import Foundation

/// A Claude Code session detected on the local machine.
struct ClaudeSession: Identifiable, Hashable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Date
    let updatedAt: Date
    let version: String
    let status: String       // "busy" or "idle" as reported by Claude Code
    let kind: String
    let entrypoint: String
    let name: String?

    /// Populated by SessionStore when we manage to match a Ghostty terminal.
    /// This is our source of truth for `isBusy` because Claude refreshes the
    /// terminal title on every spinner tick.
    var terminalTitle: String?
    var terminalId: String?

    var id: String { sessionId.isEmpty ? "\(pid)" : sessionId }

    /// Displayed label: explicit name if any, otherwise basename of cwd.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// String used to locate the matching Ghostty window.
    var windowSearchKey: String {
        if let name, !name.isEmpty { return name }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Effective busy status: priority to the Ghostty terminal title (updated
    /// by Claude on every spinner tick), fallback to the JSON `status` field.
    var isBusy: Bool {
        if let title = terminalTitle?.trimmingCharacters(in: .whitespaces),
           let first = title.unicodeScalars.first {
            // Braille range U+2800..U+28FF: Claude shows a Braille spinner when busy.
            if (0x2800...0x28FF).contains(first.value) { return true }
            // ✳ (U+2733): Claude is waiting for user input.
            if first.value == 0x2733 { return false }
        }
        return status == "busy"
    }
}
