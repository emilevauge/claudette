import AppKit
import SwiftUI
import Combine
import KeyboardShortcuts

/// Singleton controller of the app: native NSStatusItem + NSPopover.
/// We don't use SwiftUI `MenuBarExtra` because we need to open and close the
/// popover programmatically (global keyboard shortcut) and the AppKit API
/// gives us full control.
@MainActor
final class AppDelegate: NSObject, ObservableObject {

    static let shared = AppDelegate()

    let store = SessionStore()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    /// Hosting view for the SwiftUI,rendered status,bar icon. Kept as a
    /// strong reference so its CALayer animations keep ticking.
    private var statusIconHost: NSHostingView<StatusBarIcon>?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didFinishLaunching(_:)),
            name: NSApplication.didFinishLaunchingNotification,
            object: nil
        )
    }

    @objc private func didFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // App icon consistent with the menu bar and notifications.
        AppIcon.install()

        store.start()
        store.onSessionBecameIdle = { session in
            // Skip the notification when the user is already looking at this
            // session's Ghostty window/tab : it would just be noise.
            if GhosttyBridge.isViewing(session: session) { return }
            let lastText = ConversationReader.lastAssistantText(for: session)
            SystemNotifications.shared.notifyIdle(session, lastText: lastText)
        }
        SystemNotifications.shared.onClick = { session in
            _ = GhosttyBridge.focus(session: session)
        }
        SystemNotifications.shared.requestPermission()

        setupStatusItem()
        setupPopover()
        observeSessions()
        setupHotkey()

        // Background check for a newer release on GitHub: at launch, then
        // every 24h while the app is running, plus a re,check on wake.
        UpdateChecker.startPeriodicCheck()
    }

    // MARK: status item

    private func setupStatusItem() {
        // Fixed width so the SwiftUI hosting view has predictable bounds.
        let item = NSStatusBar.system.statusItem(withLength: 26)
        if let button = item.button {
            button.action = #selector(togglePopover(_:))
            button.target = self

            let host = NSHostingView(
                rootView: StatusBarIcon(phase: .empty)
            )
            host.translatesAutoresizingMaskIntoConstraints = false
            // The SwiftUI view should not steal clicks from the button.
            host.allowedTouchTypes = []
            button.addSubview(host)
            NSLayoutConstraint.activate([
                host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                host.widthAnchor.constraint(equalToConstant: 22),
                host.heightAnchor.constraint(equalToConstant: 22),
            ])
            statusIconHost = host
        }
        statusItem = item
    }

    private func setupPopover() {
        let p = NSPopover()
        p.behavior = .transient        // dismisses on click outside
        p.animates = true
        p.contentSize = NSSize(width: 380, height: 480)
        p.contentViewController = NSHostingController(
            rootView: MenuView(store: store)
        )
        popover = p
    }

    private func observeSessions() {
        // Reflect the aggregate session phase in the menu,bar icon:
        // empty (no sessions) -> outline, no pulse
        // any needs attention -> filled, red, pulse
        // any busy            -> filled, neutral tint, pulse
        // otherwise (idle)    -> filled, neutral tint, no pulse
        store.$sessions
            .map(StatusBarIcon.Phase.compute(from:))
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.statusIconHost?.rootView = StatusBarIcon(phase: phase)
            }
            .store(in: &cancellables)
    }

    // MARK: hotkey

    private func setupHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleClaudette) { [weak self] in
            self?.togglePopover(nil)
        }
    }

    // MARK: actions

    @objc func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Ensure the content (TextField) can take focus.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover?.performClose(nil)
    }
}
