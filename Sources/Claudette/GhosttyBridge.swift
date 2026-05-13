import Foundation
import AppKit

/// AppleScript bridge to drive Ghostty.
enum GhosttyBridge {

    struct GhosttyTerminal {
        let id: String
        let cwd: String
        let name: String
    }

    // MARK: public API

    /// Try to focus the window/tab/split running the given session.
    /// Strategy:
    ///   0. if SessionStore already mapped a terminal id, use it directly.
    ///   1. if we know the session's `aiTitle`, match by exact title (deterministic).
    ///   2. exact match on the terminal's `working directory`, tie,break by title.
    ///   3. if no cwd match, fallback: window whose title contains the session `name`.
    ///   4. last resort: just bring Ghostty to the front.
    @discardableResult
    static func focus(session: ClaudeSession) -> Bool {
        // 0: pre,mapped id from the store.
        if let tid = session.terminalId, focusTerminal(id: tid) { return true }

        let terminals = listTerminals()

        // 1: deterministic match via aiTitle.
        if let aiTitle = session.aiTitle, !aiTitle.isEmpty,
           let t = terminals.first(where: { titleMatches($0.name, aiTitle: aiTitle) }),
           focusTerminal(id: t.id) {
            return true
        }

        let byCwd = terminals.filter { $0.cwd == session.cwd }
        let needle = (session.name?.isEmpty == false) ? session.name! : session.windowSearchKey

        // 2: cwd match, tie,break by title.
        if !byCwd.isEmpty {
            let best = byCwd.first(where: { $0.name.contains(needle) }) ?? byCwd[0]
            if focusTerminal(id: best.id) { return true }
        }

        // 3: legacy fallback by window title.
        if focusWindow(matching: needle) { return true }

        // 4: give up and at least activate the app.
        activateApp()
        return false
    }

    /// See `SessionStore.titleMatches`: a Ghostty title matches an aiTitle if,
    /// once the leading Braille spinner or `✳` glyph is stripped, the rest
    /// equals (or starts with) the aiTitle.
    private static func titleMatches(_ title: String, aiTitle: String) -> Bool {
        var s = Substring(title)
        if let first = s.unicodeScalars.first,
           (0x2800...0x28FF).contains(first.value) || first.value == 0x2733 {
            s = s.dropFirst()
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed == aiTitle || trimmed.hasPrefix(aiTitle)
    }

    /// Enumerate every Ghostty terminal with its id, cwd and title.
    static func listTerminals() -> [GhosttyTerminal] {
        // Unlikely separator between fields.
        let SEP = "\u{1F}"   // unit separator
        let source = """
        tell application "Ghostty"
            set out to ""
            repeat with t in terminals
                try
                    set out to out & (id of t) & "\(SEP)" & (working directory of t) & "\(SEP)" & (name of t) & linefeed
                end try
            end repeat
            return out
        end tell
        """

        guard let raw = runScript(source) else { return [] }

        return raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: Character(SEP), omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            return GhosttyTerminal(
                id: String(parts[0]),
                cwd: String(parts[1]),
                name: String(parts[2])
            )
        }
    }

    /// Focus the terminal by its id. The Ghostty `focus` command (GhstFcus)
    /// brings the right window + tab + split to the front.
    @discardableResult
    static func focusTerminal(id: String) -> Bool {
        let escaped = id.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Ghostty"
            activate
            try
                set t to first terminal whose id is "\(escaped)"
                focus t
                return "ok"
            on error
                return "notfound"
            end try
        end tell
        """
        return runScript(source) == "ok"
    }

    /// Fallback: activate the window whose title contains `needle`.
    @discardableResult
    static func focusWindow(matching needle: String) -> Bool {
        let escaped = needle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        tell application "Ghostty"
            activate
            repeat with w in windows
                try
                    if name of w contains "\(escaped)" then
                        activate window w
                        return "ok"
                    end if
                end try
            end repeat
            return "notfound"
        end tell
        """
        return runScript(source) == "ok"
    }

    /// Bring Ghostty to the front without targeting any specific window.
    /// `activate(options:)` is deprecated on macOS 14+, AppleScript stays
    /// universal.
    static func activateApp() {
        runScript("tell application \"Ghostty\" to activate")
    }

    // MARK: low level

    @discardableResult
    static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}
