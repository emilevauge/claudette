import SwiftUI
import AppKit

/// The app icon, drawn in SwiftUI so it stays consistent with the notification
/// icon (same terminal glyph, same sand/brown gradient).
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
    /// Render the app icon as an NSImage and assign it to the running process.
    /// Visible in Notification Center, Cmd+Tab, Spotlight, etc.
    @MainActor
    static func install() {
        if let img = renderNSImage() {
            NSApplication.shared.applicationIconImage = img
        }
    }

    /// Render the app icon at 1024×1024 and save it as a PNG.
    /// Used by `make-app.sh` to generate the bundle's .icns.
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
