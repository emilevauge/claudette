import Foundation

/// Gère le lancement automatique de Claudette à la connexion utilisateur via
/// un LaunchAgent user (~/Library/LaunchAgents/<label>.plist).
///
/// Cette approche fonctionne avec un binaire SPM nu (pas besoin de packager
/// en .app). `SMAppService.mainApp` aurait exigé un bundle .app signé.
enum LaunchAgent {

    static let label = "dev.claudette.app"

    private static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// Chemin absolu du binaire Claudette en cours d'exécution.
    private static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Indique si le LaunchAgent est installé.
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Active le lancement au démarrage : écrit le plist + le charge dans launchd.
    static func enable() throws {
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)

        // Charge dans launchd. Si déjà chargé, on ignore l'erreur.
        _ = run("/bin/launchctl", ["load", "-w", plistURL.path])
    }

    /// Désactive le lancement au démarrage : décharge + supprime le plist.
    static func disable() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            _ = run("/bin/launchctl", ["unload", "-w", plistURL.path])
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
