import Foundation
import AppKit

/// Pont AppleScript pour piloter Ghostty.
enum GhosttyBridge {

    struct GhosttyTerminal {
        let id: String
        let cwd: String
        let name: String
    }

    // MARK: API publique

    /// Tente de focuser la fenêtre/onglet/split qui exécute la session donnée.
    /// Stratégie :
    ///   1. Match exact sur `working directory` du terminal.
    ///   2. Si plusieurs candidats, prendre celui dont le titre contient le `name` de session.
    ///   3. Si aucun match `cwd`, fallback : titre de fenêtre contenant le `name` de session.
    ///   4. En dernier recours : activer Ghostty au moins.
    @discardableResult
    static func focus(session: ClaudeSession) -> Bool {
        // 0 : si le store a déjà mappé un terminal à cette session, on l'utilise direct.
        if let tid = session.terminalId, focusTerminal(id: tid) { return true }

        let terminals = listTerminals()
        let byCwd = terminals.filter { $0.cwd == session.cwd }
        let needle = (session.name?.isEmpty == false) ? session.name! : session.windowSearchKey

        // 1 & 2 : match par cwd, départage par nom.
        if !byCwd.isEmpty {
            let best = byCwd.first(where: { $0.name.contains(needle) }) ?? byCwd[0]
            if focusTerminal(id: best.id) { return true }
        }

        // 3 : fallback ancien matching par titre de fenêtre.
        if focusWindow(matching: needle) { return true }

        // 4 : abandon, on active au moins l'app.
        activateApp()
        return false
    }

    /// Énumère tous les terminaux Ghostty avec leur id, cwd et titre.
    static func listTerminals() -> [GhosttyTerminal] {
        // Séparateur improbable entre champs.
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

    /// Focus le terminal par son id (la commande `focus` GhstFcus amène fenêtre + onglet + split).
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

    /// Fallback : active la fenêtre dont le titre contient `needle`.
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

    /// Active Ghostty sans cibler de fenêtre précise.
    /// `activate(options:)` est déprécié macOS 14+, on passe par AppleScript
    /// qui reste universel.
    static func activateApp() {
        runScript("tell application \"Ghostty\" to activate")
    }

    // MARK: bas niveau

    @discardableResult
    static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}
