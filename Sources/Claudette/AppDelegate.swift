import AppKit
import SwiftUI
import Combine
import KeyboardShortcuts

/// Controller singleton de l'app : NSStatusItem + NSPopover AppKit purs.
/// On abandonne `MenuBarExtra` SwiftUI pour pouvoir ouvrir/fermer le popover
/// programmatiquement de manière fiable depuis le hotkey global.
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

        // Icône d'app cohérente avec la barre de menus et les notifs.
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
        p.behavior = .transient        // se ferme au clic hors du popover
        p.animates = true
        p.contentSize = NSSize(width: 380, height: 480)
        p.contentViewController = NSHostingController(
            rootView: MenuView(store: store)
        )
        popover = p
    }

    private func observeSessions() {
        // Bascule l'icône selon qu'au moins une session est busy.
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
            // S'assure que le contenu (TextField) puisse prendre le focus.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover?.performClose(nil)
    }
}
