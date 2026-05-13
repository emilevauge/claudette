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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "terminal",
                                   accessibilityDescription: "Claudette")
            button.action = #selector(togglePopover(_:))
            button.target = self
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
        // Switch the menu bar icon depending on whether any session is busy.
        store.$sessions
            .map { $0.contains(where: { $0.isBusy }) }
            .removeDuplicates()
            .sink { [weak self] busy in
                self?.statusItem?.button?.image = NSImage(
                    systemSymbolName: busy ? "terminal.fill" : "terminal",
                    accessibilityDescription: "Claudette"
                )
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
