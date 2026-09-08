import SwiftUI
import AppKit

@main
struct ClaudetteApp: App {
    // Keep a strong ref to the controller so SwiftUI doesn't release it.
    // Initializing `AppDelegate.shared` registers the observer for
    // `NSApplication.didFinishLaunchingNotification`.
    @StateObject private var delegate = AppDelegate.shared

    init() {
        // CLI utility mode: render the app icon as a PNG then exit.
        // Used by make-app.sh to produce the bundle's .icns.
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--generate-icon"),
           idx + 1 < args.count {
            let path = args[idx + 1]
            let ok = MainActor.assumeIsolated { AppIcon.writePNG(to: path) }
            exit(ok ? 0 : 1)
        }

        // Single instance. The LaunchAgent, the self-updater and a manual
        // `open` can each start Claudette while another copy (possibly from
        // a different bundle path) is already running. Two copies fight over
        // the status item and, because each ad-hoc build has its own cdhash,
        // trigger the Accessibility prompt on every switch. The newcomer
        // yields to the running instance.
        if Self.anotherInstanceIsRunning() {
            NSLog("Claudette: another instance is already running, exiting")
            exit(0)
        }
    }

    /// True when another process with our bundle identifier is alive.
    private static func anotherInstanceIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    var body: some Scene {
        // SwiftUI requires at least one Scene, but the real Settings UI
        // lives in a popover anchored to the gear button inside the menu
        // bar popover. This Scene exists only to satisfy that
        // requirement; the empty `CommandGroup(replacing: .appSettings)`
        // removes the system "Settings…" menu entry and its default
        // ⌘, shortcut so the empty Settings window is never reachable.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
            }
    }
}
