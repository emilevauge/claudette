import Foundation

/// Manages "launch Claudette at login" via a user LaunchAgent
/// (`~/Library/LaunchAgents/<label>.plist`).
///
/// This approach works with a raw SPM binary (no .app bundle required).
/// `SMAppService.mainApp` would have required a signed .app bundle.
enum LaunchAgent {

    static let label = "dev.claudette.app"

    private static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// Absolute path of the currently running Claudette executable.
    private static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// Whether the LaunchAgent is installed.
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Enable launch at login: write the plist and load it in launchd.
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

        // Load into launchd. Ignore failure if it's already loaded.
        _ = run("/bin/launchctl", ["load", "-w", plistURL.path])
    }

    /// Disable launch at login: unload from launchd and delete the plist.
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
