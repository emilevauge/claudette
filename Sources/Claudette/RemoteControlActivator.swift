import Foundation

/// Flips a Claude Code session into `/remote-control` mode without
/// requiring the user to switch to its terminal first. Claude Code
/// exposes `/remote-control` only as an in,session slash command (no
/// file or IPC equivalent), so we drive it through AppleScript via
/// Ghostty's own `input text` verb : the text is delivered as if it
/// was pasted, which bypasses the slash command picker that would
/// otherwise auto-complete to a different `/remote-*` command while
/// the characters arrive (e.g. `/remote-env`). The session prints
/// its QR code on return ; the user scans it with the Claude mobile
/// app and the rest of the interaction (chat, AskUserQuestion answers,
/// transcript) is handled by Anthropic's existing infrastructure.
///
/// Idempotent : re-firing on a session that's already remote just
/// re,displays the QR. No-op for Claude Desktop background agents
/// (`isClaudeDesktop == true`) since they have no terminal of their
/// own, and for sessions whose terminal couldn't be matched.
enum RemoteControlActivator {

    @discardableResult
    static func enable(session: ClaudeSession) -> Bool {
        guard !session.isClaudeDesktop,
              let terminalId = session.terminalId,
              !terminalId.isEmpty else {
            return false
        }
        // Focus first so the user sees the QR code immediately after
        // the slash command is delivered. `input text` works without
        // focus too, but a hidden terminal showing a QR is unhelpful.
        _ = GhosttyBridge.focusTerminal(id: terminalId)
        return sendSlashCommand("/remote-control", toTerminalId: terminalId)
    }

    /// Paste a slash command into the targeted Ghostty terminal via
    /// Ghostty's native `input text` (no System Events keystroke),
    /// then submit it with a `send key "enter"`. `input text`
    /// delivers the string atomically so Claude Code's slash command
    /// picker never sees a partial filter that would auto-resolve to
    /// the wrong command.
    @discardableResult
    private static func sendSlashCommand(_ command: String,
                                         toTerminalId terminalId: String) -> Bool {
        let escapedId = terminalId.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedCmd = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Ghostty"
            try
                set t to first terminal whose id is "\(escapedId)"
                input text "\(escapedCmd)" to t
                send key "enter" to t
                return "ok"
            on error
                return "notfound"
            end try
        end tell
        """
        return GhosttyBridge.runScript(source) == "ok"
    }
}
