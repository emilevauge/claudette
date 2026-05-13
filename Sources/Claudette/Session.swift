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

    /// Populated by SessionStore when we manage to match a Ghostty terminal.
    /// This is our source of truth for `isBusy` because Claude refreshes the
    /// terminal title on every spinner tick.
    var terminalTitle: String?
    var terminalId: String?

    /// Refined idle state, read from the JSONL transcript. Used to
    /// distinguish a clean turn end (Claude is done, user can move on)
    /// from a state where Claude is blocked waiting for the user to act,
    /// be it a permission prompt or a structured `AskUserQuestion`.
    var idleKind: IdleKind = .unknown

    var id: String { sessionId.isEmpty ? "\(pid)" : sessionId }

    /// True when this session is a Claude Desktop background agent rather
    /// than an interactive `claude` CLI invocation in a terminal. Routed to
    /// `ClaudeDesktopBridge` for focus; never matched against Ghostty.
    var isClaudeDesktop: Bool { entrypoint == "claude-desktop" }

    /// Refined idle state, surfaced through `idleKind`.
    enum IdleKind: Equatable {
        /// We could not determine the kind from the JSONL (transcript
        /// missing or too short). Treated as `.idle` by the UI.
        case unknown
        /// Claude finished its turn cleanly. JSONL signature: latest
        /// relevant entry is a `system / subtype: turn_duration`, or an
        /// `assistant` whose `stop_reason` is `end_turn` / `stop_sequence`.
        case idle
        /// Claude is blocked waiting for a user action : either a tool
        /// permission prompt (any tool gated by `--permission-mode`) or a
        /// structured `AskUserQuestion`. JSONL signature: the latest
        /// `assistant` has `stop_reason: tool_use` and no `user / tool_result`
        /// matches its `tool_use_id` in subsequent entries.
        case needsAttention
    }

    /// Effective phase combining the busy/idle title heuristic and the
    /// refined JSONL state. The UI maps this to color, label and pulse.
    enum Phase {
        case busy
        case needsAttention
        case idle
    }

    var phase: Phase {
        if isBusy { return .busy }
        switch idleKind {
        case .needsAttention: return .needsAttention
        case .idle, .unknown: return .idle
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
