import Foundation
import AppKit
import UserNotifications

/// Notifications système natives via UNUserNotificationCenter.
/// Le système gère présentation, durée, son, centre de notifications, clic.
@MainActor
final class SystemNotifications: NSObject, UNUserNotificationCenterDelegate {

    static let shared = SystemNotifications()

    /// Callback exécuté quand l'utilisateur clique sur une notif Claudette.
    var onClick: ((ClaudeSession) -> Void)?

    /// Tableau d'index pour retrouver la ClaudeSession à partir du sessionId
    /// stocké dans `userInfo` (UserNotifications ne sérialise pas nos objets).
    private var pending: [String: ClaudeSession] = [:]

    /// `UNUserNotificationCenter` exige que Bundle.main ait un CFBundleIdentifier.
    /// Sans ça (cas du binaire SPM lancé directement, pas dans un .app), tout
    /// appel crash. On désactive proprement les notifs dans ce cas.
    private let available: Bool = (Bundle.main.bundleIdentifier != nil)

    private override init() {
        super.init()
        if available {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Demande la permission standard : au premier lancement macOS affiche
    /// le dialogue « Claudette souhaite envoyer des notifications ». Sans
    /// `.provisional`, on récupère le comportement banner normal.
    func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in /* ignoré */ }
    }

    /// Envoie une notif système pour une session passée en attente.
    /// Si Claudette est lancée comme un vrai .app (avec bundle ID), utilise
    /// `UNUserNotificationCenter` (clic interactif). Sinon (binaire SPM nu en dev),
    /// fallback sur `display notification` via AppleScript (pas de clic mais
    /// le visuel est identique côté macOS).
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

        // Mémorise la session pour le callback de clic.
        pending[session.id] = session

        let request = UNNotificationRequest(
            identifier: "claudette.idle.\(session.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            // Si UN refuse (permission denied, bundle non enregistré…), fallback
            // sur AppleScript pour que l'utilisateur voie quand même une notif.
            if error != nil {
                Task { @MainActor in
                    self?.notifyViaAppleScript(session, lastText: lastText)
                }
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Permet à la notif d'apparaitre même si Claudette a (théoriquement) le focus.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Clic ou action sur la notif : on focus la fenêtre Ghostty.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let id = info["sessionId"] as? String {
            Task { @MainActor in
                if let session = self.pending[id] {
                    self.onClick?(session)
                    self.pending.removeValue(forKey: id)
                }
            }
        }
        completionHandler()
    }

    // MARK: fallback AppleScript

    /// Affiche une notif via `display notification` (osascript), pour les
    /// cas où l'app n'a pas de bundle ID (binaire SPM lancé directement en dev).
    /// Pas de callback de clic, mais visuel identique à une vraie notif macOS.
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
