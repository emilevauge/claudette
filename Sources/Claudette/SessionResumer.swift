import Foundation

/// Reopens a closed session in a new Ghostty window, running
/// `claude --resume <sessionId>` in the session's original directory.
///
/// Ghostty's scripting dictionary can build a window from a "surface
/// configuration", which carries an initial working directory and an initial
/// input string. We use both: the window opens in the right directory and the
/// command is delivered to the shell as if typed.
///
/// Why not `open -na Ghostty.app --args --working-directory=… -e claude …`,
/// which Ghostty documents for the CLI: `-n` starts a *second* Ghostty
/// instance alongside the running one, which then owns its own window list
/// and answers the Apple Events Claudette sends to match and focus sessions.
/// Going through the running instance avoids that entirely.
///
/// Delivering the command as terminal input rather than as the window's
/// `command` also keeps the user's shell in the loop, so `claude` is resolved
/// from their own PATH (typically `~/.local/bin`), which the app's launchd
/// environment doesn't have.
enum SessionResumer {

    @discardableResult
    static func resume(_ session: ClosedSession) -> Bool {
        launch(cwd: session.cwd, sessionId: session.sessionId)
    }

    @discardableResult
    static func launch(cwd: String, sessionId: String) -> Bool {
        let source = """
        tell application "Ghostty"
            activate
            set cfg to new surface configuration
            set initial working directory of cfg to "\(escape(cwd))"
            set initial input of cfg to "claude --resume \(escape(sessionId))\\n"
            new window with configuration cfg
            return "ok"
        end tell
        """
        return GhosttyBridge.runScript(source) == "ok"
    }

    /// Escape for an AppleScript string literal.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
