import SwiftUI
import AppKit

/// Icône de l'application, dessinée en SwiftUI pour rester cohérente avec
/// l'icône de la notif (même glyphe terminal, même gradient sand/brown).
struct AppIconView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.92, green: 0.78, blue: 0.55),
                    Color(red: 0.77, green: 0.56, blue: 0.31)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous))

            Image(systemName: "terminal")
                .font(.system(size: 520, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 1024, height: 1024)
    }
}

enum AppIcon {
    /// Rend l'icône d'app en NSImage et l'affecte au process en cours.
    /// Visible dans Notification Center, Cmd+Tab, Spotlight, etc.
    @MainActor
    static func install() {
        if let img = renderNSImage() {
            NSApplication.shared.applicationIconImage = img
        }
    }

    /// Rend l'icône d'app à 1024×1024 et l'enregistre en PNG.
    /// Utilisé par `make-app.sh` pour générer le .icns du bundle.
    @MainActor
    static func writePNG(to path: String) -> Bool {
        guard let img = renderNSImage(),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    @MainActor
    private static func renderNSImage() -> NSImage? {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        return renderer.nsImage
    }
}
