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

    /// Latest LLM,generated title for this session, read from the JSONL
    /// transcript (`{"type":"ai-title","aiTitle":"..."}` entries). This is
    /// exactly the string Claude Code injects into the Ghostty tab title
    /// (modulo the leading spinner/`✳` glyph), so it doubles as a perfect
    /// matching key when annotating with a Ghostty terminal.
    var aiTitle: String?

    /// Context window fill (0..1), read straight from the status JSON
    /// Claude Code writes for the status line (`used_percentage` divided
    /// by 100). `nil` when the side,channel file hasn't been produced
    /// yet, or the user opted out of the integration.
    var contextFraction: Double?

    /// True when the JSONL shows an unresolved background tool call : a
    /// subagent (`Agent`) or a `Bash` with `run_in_background: true`.
    /// Claude Code flips `status` back to "idle" / "shell" as soon as
    /// the main turn ends, even while the background task is still
    /// running, so the field alone misses these. Populated by
    /// SessionStore on each refresh.
    var hasBackgroundWork: Bool = false

    /// Subagents whose transcript is being actively written (mtime within
    /// the last few seconds). Drives the inline counter next to the
    /// status label and the hover tooltip listing each agent's type and
    /// description. Populated by SessionStore on each refresh.
    var activeSubagents: [ActiveSubagent] = []

    /// Populated by SessionStore when we manage to match a Ghostty terminal.
    /// This is our source of truth for `isBusy` because Claude refreshes the
    /// terminal title on every spinner tick.
    var terminalTitle: String?
    var terminalId: String?

    var id: String { sessionId.isEmpty ? "\(pid)" : sessionId }

    /// True when this session is a Claude Desktop background agent rather
    /// than an interactive `claude` CLI invocation in a terminal. Routed to
    /// `ClaudeDesktopBridge` for focus; never matched against Ghostty.
    var isClaudeDesktop: Bool { entrypoint == "claude-desktop" }

    /// Effective phase. The UI maps this to color, label and pulse.
    enum Phase {
        case busy
        case needsAttention
        case idle
    }

    /// Observed `status` values from `~/.claude/sessions/<pid>.json` :
    ///   - "busy"    : the model is producing output.
    ///   - "waiting" : the CLI is blocked on a user response, either a
    ///                 structured `AskUserQuestion` or a permission prompt.
    ///   - "idle"    : the turn is fully wrapped up, plain `>` prompt.
    ///   - "shell"   : the main turn ended, but Claude Code is still
    ///                 keeping state (often correlates with a background
    ///                 task still running). Treated like "idle" except
    ///                 that `hasBackgroundWork` is allowed to bump us to
    ///                 .busy.
    /// We map them directly. Anything unrecognised (including `null` for
    /// Claude Desktop agents) falls back to the title,based busy detection.
    ///
    /// `hasBackgroundWork` is an additional override : when true and the
    /// status reports nothing active (idle / shell / unknown), the row
    /// shows .busy so the user sees the session has work in flight.
    var phase: Phase {
        switch status {
        case "busy":    return .busy
        case "waiting": return .needsAttention
        case "idle":    return hasBackgroundWork ? .busy : .idle
        case "shell":   return hasBackgroundWork ? .busy : .idle
        default:
            if hasBackgroundWork { return .busy }
            return isBusy ? .busy : .idle
        }
    }

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

/// One subagent currently writing to its transcript. We surface the type
/// (`general-purpose`, `code-reviewer`, ...) and the short description
/// Claude provided when spawning it, so the user can tell at a glance
/// what each running agent is doing.
struct ActiveSubagent: Hashable {
    let agentType: String
    let description: String
}
