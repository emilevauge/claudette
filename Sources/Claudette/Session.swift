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

    /// JSONL-derived override for `phase` : `true` when the transcript
    /// shows Claude has an unresolved `tool_use` (an `AskUserQuestion`,
    /// or another tool whose result hasn't landed within ~5 s, which in
    /// practice means Claude Code is showing a permission prompt). Set by
    /// SessionStore on each refresh. Overrides a stale `status: "busy"`
    /// from `~/.claude/sessions/<pid>.json` — Claude Code v2.1.141 leaves
    /// that field at "busy" during AskUserQuestion / permission prompts.
    var blockedOnUser: Bool = false

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

    /// The Claude Code daemon writes the session JSON with three observed
    /// `status` values :
    ///   - "busy"    : the model is producing output (in theory).
    ///   - "waiting" : the CLI is blocked on a user response, either a
    ///                 structured `AskUserQuestion` or a permission prompt.
    ///   - "idle"    : the turn is fully wrapped up, plain `>` prompt.
    ///
    /// In practice (Claude Code v2.1.141) `status` sometimes stays at
    /// "busy" while the CLI is actually showing an AskUserQuestion or a
    /// permission prompt : the field is no longer authoritative for that
    /// transition. So we cross-check with `blockedOnUser`, derived from
    /// the JSONL transcript, which DOES contain the pending tool_use
    /// entry the moment Claude emits it. `blockedOnUser` overrides a
    /// "busy" status; `status: "waiting"` is still trusted on its own.
    var phase: Phase {
        switch status {
        case "waiting": return .needsAttention
        case "idle":    return .idle
        case "busy":    return blockedOnUser ? .needsAttention : .busy
        default:        return isBusy ? .busy : .idle
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
