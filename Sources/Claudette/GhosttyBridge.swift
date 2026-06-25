import Foundation
import AppKit
import ApplicationServices

/// Bridge to observe and drive Ghostty.
///
/// Two transports, used for different jobs:
///   - **Accessibility API** (`AXUIElement`) for the hot path: enumerating
///     terminal *titles* on every poll. No Apple Event IPC, so it's cheap
///     enough to run at the full poll rate. Titles only ; no cwd, no id.
///   - **AppleScript** for on-demand actions (focus a specific terminal) and
///     as a fallback when Accessibility hasn't been granted yet. AppleScript
///     is the only Ghostty interface that exposes a terminal `id` and
///     `working directory`, but each call is a costly Apple Event round-trip,
///     so we keep it off the poll loop.
enum GhosttyBridge {

    static let bundleID = "com.mitchellh.ghostty"

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
        // 0: pre,mapped id from the store. The AX poll path leaves `terminalId`
        // empty (AX exposes no Ghostty id), so guard against the empty string.
        if let tid = session.terminalId, !tid.isEmpty, focusTerminal(id: tid) {
            return true
        }

        // Focus needs the Ghostty terminal `id`, which only AppleScript
        // exposes ; the AX poll path can't provide it. Enumerate via
        // AppleScript here (on-demand, off the hot poll loop).
        let terminals = listTerminalsViaAppleScript()

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

    /// Field separator for `listTerminals`: an unlikely unit-separator byte.
    private static let SEP = "\u{1F}"

    /// Enumerate Ghostty terminals for the poll loop.
    ///
    /// Prefers the Accessibility API (no Apple Event, cheap). Returns titles
    /// only: `id` and `cwd` are empty, because the matcher keys on the title
    /// (Claude injects the aiTitle into the tab title) and the session's cwd
    /// is already known from its JSON. Falls back to AppleScript when
    /// Accessibility hasn't been granted, so the feature keeps working
    /// (just more expensively) until the user enables it.
    static func listTerminals() -> [GhosttyTerminal] {
        if let viaAX = listTerminalsViaAX() { return viaAX }
        return listTerminalsViaAppleScript()
    }

    // MARK: Accessibility transport (hot path)

    /// Read every Ghostty window title via the Accessibility API. Returns
    /// `nil` (not an empty list) when the app isn't trusted yet, so the
    /// caller can fall back to AppleScript ; returns `[]` when Ghostty simply
    /// has no windows. Titles only.
    ///
    /// Limitation: macOS native tabs expose only the *active* tab's title at
    /// the window level, so a Claude session sitting in a background tab may
    /// not be matched until it's fronted. That's the same trade-off any
    /// title-reading API hits, and the busy session is usually the fronted one.
    static func listTerminalsViaAX() -> [GhosttyTerminal]? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return [] }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }

        return windows.compactMap { window in
            guard let title = axString(window, kAXTitleAttribute), !title.isEmpty else { return nil }
            return GhosttyTerminal(id: "", cwd: "", name: title)
        }
    }

    /// Copy a string-valued accessibility attribute, or `nil`.
    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    /// Whether the app is trusted to use the Accessibility API. Pass
    /// `prompt: true` once at startup to surface the system permission dialog
    /// (it deep-links the user to System Settings ; it does nothing on repeat
    /// calls once granted). Reading other apps' titles via AX requires this.
    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: AppleScript transport (on-demand + fallback)

    /// The enumeration script is a static literal (only the constant `SEP` is
    /// interpolated), so we compile it once and reuse the instance:
    /// `NSAppleScript` caches its compiled bytecode after the first
    /// `executeAndReturnError`, skipping the parse pass on later calls. The
    /// dominant cost is still the Apple Event IPC round-trip, which is why
    /// this transport is reserved for on-demand focus and the no-AX fallback.
    private static let listTerminalsScript: NSAppleScript? = NSAppleScript(source: """
    tell application "Ghostty"
        set out to ""
        repeat with t in terminals
            try
                set out to out & (id of t) & "\(SEP)" & (working directory of t) & "\(SEP)" & (name of t) & linefeed
            end try
        end repeat
        return out
    end tell
    """)

    /// Enumerate every Ghostty terminal with its id, cwd and title via
    /// AppleScript. Costly (Apple Event IPC) ; used by `focus` and as the
    /// fallback when Accessibility isn't granted.
    static func listTerminalsViaAppleScript() -> [GhosttyTerminal] {
        guard let script = listTerminalsScript else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let raw = result.stringValue else { return [] }

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
