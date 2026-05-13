import Foundation
import AppKit

/// Activate Claude Desktop (Electron app) for sessions whose `entrypoint` is
/// `claude-desktop`. Those sessions are background agent tasks driven by the
/// app, with no controlling terminal, so the Ghostty bridge has nothing to
/// match them against.
///
/// We only bring the app to the front for now. The `claude://` URL scheme
/// exists but is reserved for auth and artifact sharing; there is no public
/// deep,link path to focus a specific conversation. If one ships later, this
/// is the place to wire it.
enum ClaudeDesktopBridge {

    static let bundleIdentifier = "com.anthropic.claudefordesktop"

    @discardableResult
    static func focus(session: ClaudeSession) -> Bool {
        return activate()
    }

    /// Bring Claude.app to the front. Returns false if the app is not
    /// installed or the launch request fails.
    @discardableResult
    static func activate() -> Bool {
        let ws = NSWorkspace.shared

        // Already running: just unhide and bring to front. On macOS 14+ the
        // legacy options are a no,op, so the parameterless form is preferred.
        if let app = ws.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) {
            app.activate()
            return true
        }

        // Not running: launch it.
        guard let url = ws.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        var ok = true
        let sema = DispatchSemaphore(value: 0)
        ws.openApplication(at: url, configuration: config) { _, error in
            if error != nil { ok = false }
            sema.signal()
        }
        // Short wait so the caller can rely on the return value.
        _ = sema.wait(timeout: .now() + 2)
        return ok
    }

    /// Whether Claude Desktop is installed on this machine.
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}
