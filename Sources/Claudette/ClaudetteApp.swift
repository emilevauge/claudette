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
        // SwiftUI requires at least one scene. The Settings scene is hidden
        // until the user explicitly opens "Settings…".
        Settings {
            SettingsView()
                .onDisappear {
                    // Back to accessory to hide the Dock icon.
                    NSApp.setActivationPolicy(.accessory)
                }
        }
    }
}
