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
