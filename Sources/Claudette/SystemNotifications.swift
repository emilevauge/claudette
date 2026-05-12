import Foundation
import AppKit
import UserNotifications

/// Native system notifications through UNUserNotificationCenter. The system
/// owns presentation, duration, sound, the Notification Center and click
/// handling.
@MainActor
final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate {

    static let shared = SystemNotifications()

    /// Callback fired when the user clicks a session notification.
    var onClick: ((ClaudeSession) -> Void)?

    /// Index used to recover the ClaudeSession from the `sessionId` stored
    /// in `userInfo` (UserNotifications doesn't serialize our objects).
    private var pending: [String: ClaudeSession] = [:]

    /// `UNUserNotificationCenter` requires Bundle.main to have a
    /// CFBundleIdentifier. Without it (SPM binary launched directly, not in a
    /// .app), every call crashes. We disable notifications cleanly in that case.
    private let available: Bool = (Bundle.main.bundleIdentifier != nil)

    private override init() {
        super.init()
        if available {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Request the standard permission. On first launch macOS shows the
    /// "Claudette would like to send you notifications" dialog. Without
    /// `.provisional` we get the regular banner behaviour.
    func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in /* ignored */ }
    }

    /// Send an "update available" notification. Clicking it opens the GitHub
    /// release page in the user's default browser.
    func notifyUpdateAvailable(version: String, url: URL) {
        let content = UNMutableNotificationContent()
        content.title = L("Update available")
        content.body = L("Claudette \(version) is available. Click to open the release.")
        content.sound = .default
        content.userInfo = ["openURL": url.absoluteString]

        guard available else {
            notifyUpdateViaAppleScript(version: version, url: url)
            return
        }

        let request = UNNotificationRequest(
            identifier: "claudette.update.\(version)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error != nil {
                Task { @MainActor in
                    self?.notifyUpdateViaAppleScript(version: version, url: url)
                }
            }
        }
    }

    private func notifyUpdateViaAppleScript(version: String, url: URL) {
        let title = escape(L("Update available"))
        let body = escape(L("Claudette \(version) is available."))
        let source = """
        display notification "\(body)" with title "\(title)" sound name "Glass"
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        // AppleScript "display notification" cannot embed a clickable URL;
        // the user opens the release page manually.
    }

    /// Send a system notification when a session transitions to idle.
    /// If Claudette runs as a proper .app (with bundle ID), use
    /// `UNUserNotificationCenter` (clickable). Otherwise (raw SPM binary in
    /// dev), fall back to AppleScript `display notification` (no click but
    /// visually identical to a real macOS notification).
    func notifyIdle(_ session: ClaudeSession, lastText: String?) {
        guard available else {
            notifyViaAppleScript(session, lastText: lastText)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = session.displayName
        content.subtitle = prettyPath(session.cwd)
        if let lastText, !lastText.isEmpty {
            content.body = String(lastText.prefix(400))
        } else {
            content.body = L("Claude is waiting for input")
        }
        content.sound = .default
        content.userInfo = ["sessionId": session.id]

        // Remember the session so we can dispatch the click callback.
        pending[session.id] = session

        let request = UNNotificationRequest(
            identifier: "claudette.idle.\(session.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            // If UN fails (denied, bundle not registered…), fall back to
            // AppleScript so the user still sees a notification.
            if error != nil {
                Task { @MainActor in
                    self?.notifyViaAppleScript(session, lastText: lastText)
                }
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the notification even while Claudette has (theoretically) focus.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Click or action on the notification: focus the Ghostty window.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let urlString = info["openURL"] as? String, let url = URL(string: urlString) {
            // "Update available" notification: open the release page.
            Task { @MainActor in NSWorkspace.shared.open(url) }
        } else if let id = info["sessionId"] as? String {
            Task { @MainActor in
                if let session = self.pending[id] {
                    self.onClick?(session)
                    self.pending.removeValue(forKey: id)
                }
            }
        }
        completionHandler()
    }

    // MARK: AppleScript fallback

    /// Show a notification via AppleScript `display notification`, for cases
    /// where the app has no bundle ID (SPM binary launched directly in dev).
    /// No click callback, but the visual is identical to a real macOS notification.
    private func notifyViaAppleScript(_ session: ClaudeSession, lastText: String?) {
        let title = escape(session.displayName)
        let subtitle = escape(prettyPath(session.cwd))
        let body: String = {
            if let lastText, !lastText.isEmpty {
                return escape(String(lastText.prefix(300))
                    .replacingOccurrences(of: "\n", with: " "))
            } else {
                return escape(L("Claude is waiting for input"))
            }
        }()

        let source = """
        display notification "\(body)" with title "\(title)" subtitle "\(subtitle)" sound name "Glass"
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: util

    private func prettyPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
