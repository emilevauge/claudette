import SwiftUI
import AppKit

@main
struct ClaudetteApp: App {
    // Garde une ref vers le controller pour que SwiftUI ne le libère pas.
    // L'initialisation de `AppDelegate.shared` enregistre l'observer
    // `NSApplication.didFinishLaunchingNotification`.
    @StateObject private var delegate = AppDelegate.shared

    init() {
        // Mode utilitaire CLI : rend l'icône d'app en PNG puis exit.
        // Utilisé par make-app.sh pour produire le .icns du bundle.
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--generate-icon"),
           idx + 1 < args.count {
            let path = args[idx + 1]
            let ok = MainActor.assumeIsolated { AppIcon.writePNG(to: path) }
            exit(ok ? 0 : 1)
        }
    }

    var body: some Scene {
        // SwiftUI a besoin d'au moins une scène. On utilise la Settings scene,
        // qui n'est visible qu'à l'ouverture explicite de "Réglages…".
        Settings {
            SettingsView()
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
    }
}
