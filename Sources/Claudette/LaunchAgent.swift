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

    /// Executable path recorded in the installed plist, or `nil`.
    private static var installedProgramPath: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String]
        else { return nil }
        return args.first
    }

    /// Repoint the LaunchAgent at the running copy when the recorded path is
    /// stale. `enable()` captures whichever binary was running at toggle
    /// time, typically a dev build. Later the user installs (or the
    /// self-updater swaps in) `/Applications/Claudette.app`, and launchd
    /// keeps starting the old copy at login next to the new one. We rewrite
    /// the plist when the recorded binary is gone, or when we run from
    /// `/Applications` and the plist points elsewhere. Only the file is
    /// rewritten: launchd re-reads it at next login, and reloading now would
    /// spawn a second copy immediately (`RunAtLoad`).
    static func syncIfNeeded() {
        guard isEnabled, let recorded = installedProgramPath else { return }
        let current = executablePath
        guard recorded != current else { return }
        let recordedExists = FileManager.default.fileExists(atPath: recorded)
        let runningFromApplications = current.hasPrefix("/Applications/")
        guard !recordedExists || runningFromApplications else { return }
        do {
            try writePlist()
            NSLog("Claudette: LaunchAgent repointed from %@ to %@", recorded, current)
        } catch {
            NSLog("Claudette: LaunchAgent sync failed: %@", "\(error)")
        }
    }

    /// Enable launch at login: write the plist and load it in launchd.
    static func enable() throws {
        try writePlist()
        // Load into launchd. Ignore failure if it's already loaded. With
        // `RunAtLoad` this starts a copy right away; the single-instance
        // guard in `ClaudetteApp` makes that copy exit immediately.
        _ = run("/bin/launchctl", ["load", "-w", plistURL.path])
    }

    /// Write the plist pointing at the running executable.
    private static func writePlist() throws {
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
