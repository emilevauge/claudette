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

    /// Notification category identifiers. `nonisolated` so the delegate
    /// dispatch (which runs off the main actor) can match against them.
    nonisolated static let updateCategoryId = "claudette.update.available"
    /// Action identifiers (must match what we register in
    /// `registerCategories()`).
    nonisolated static let updateActionNowId = "claudette.update.now"
    nonisolated static let updateActionNotesId = "claudette.update.notes"

    private override init() {
        super.init()
        if available {
            UNUserNotificationCenter.current().delegate = self
            registerCategories()
        }
    }

    /// How long an "idle" notification stays in Notification Center
    /// before being silently removed. Banner duration on screen is
    /// controlled by the user's macOS preferences (Banners vs Alerts);
    /// this only affects the historical entry.
    private static let idleAutoRemoveDelay: TimeInterval = 30

    /// Schedule a one,shot removal of `id` from Notification Center after
    /// `idleAutoRemoveDelay` seconds.
    private func scheduleAutoRemove(id: String) {
        let delay = Self.idleAutoRemoveDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [id]
            )
        }
    }

    /// Declare the "Update available" notification category with its action
    /// buttons. Must be called before adding a notification request that
    /// uses this category.
    private func registerCategories() {
        let updateNow = UNNotificationAction(
            identifier: Self.updateActionNowId,
            title: L("Update"),
            options: [.foreground]
        )
        let notes = UNNotificationAction(
            identifier: Self.updateActionNotesId,
            title: L("Release notes"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.updateCategoryId,
            actions: [updateNow, notes],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
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

    /// Send an "update available" notification. Two actions:
    ///   "Update" : drives `SelfUpdater.run(dmgURL:)` when a DMG asset URL
    ///              is available, otherwise opens the release page.
    ///   "Release notes" (and the default body tap) : opens the release page.
    func notifyUpdateAvailable(version: String, pageURL: URL, dmgURL: URL?) {
        let content = UNMutableNotificationContent()
        content.title = L("Update available")
        content.body = L("Claudette \(version) is available. Click to open the release.")
        content.sound = .default
        content.categoryIdentifier = Self.updateCategoryId
        var info: [String: Any] = ["openURL": pageURL.absoluteString]
        if let dmgURL { info["dmgURL"] = dmgURL.absoluteString }
        content.userInfo = info

        guard available else {
            notifyUpdateViaAppleScript(version: version, url: pageURL)
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
                    self?.notifyUpdateViaAppleScript(version: version, url: pageURL)
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
        content.interruptionLevel = .active
        content.userInfo = ["sessionId": session.id]

        // Remember the session so we can dispatch the click callback.
        pending[session.id] = session

        let id = "claudette.idle.\(session.id)"
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil
        )
        scheduleAutoRemove(id: id)
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

    /// Click or action on the notification.
    /// Routing:
    ///   - "Update" action: trigger `SelfUpdater` with the DMG URL when
    ///     present, otherwise fall back to opening the release page.
    ///   - "Release notes" action and default body tap: open the release
    ///     page in the browser.
    ///   - Idle session notification: focus the Ghostty terminal.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier

        if action == Self.updateActionNowId,
           let dmgString = info["dmgURL"] as? String,
           let dmgURL = URL(string: dmgString) {
            Task { @MainActor in await SelfUpdater.run(dmgURL: dmgURL) }
        } else if let urlString = info["openURL"] as? String,
                  let url = URL(string: urlString) {
            // Default tap, "Release notes", or "Update" without a DMG asset:
            // open the release page.
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
