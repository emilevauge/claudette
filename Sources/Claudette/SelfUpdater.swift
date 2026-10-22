import Foundation
import AppKit

/// Self,update flow triggered from the "Update" notification action.
///
/// The app cannot rewrite its own bundle while running (binary is locked),
/// so we stage the helper shell script of `SelfUpdateScript` in a tmp dir,
/// spawn it detached, then terminate ourselves. The script waits for our PID
/// to exit, mounts the DMG, checks the new app's signature against ours,
/// replaces the bundle in place, strips the quarantine xattr, and relaunches
/// Claudette.
@MainActor
enum SelfUpdater {

    enum UpdateError: Error, CustomStringConvertible {
        case notInBundle
        case bundleNotWritable
        case downloadFailed(Int?)
        case writeFailed
        case spawnFailed(Error)
        case unsigned

        var description: String {
            switch self {
            case .notInBundle:
                return "running from a non,bundled binary (no .app)"
            case .bundleNotWritable:
                return "bundle directory is not writable"
            case .downloadFailed(let code):
                return "download failed (HTTP \(code.map(String.init) ?? "?"))"
            case .writeFailed:
                return "could not stage the helper script"
            case .spawnFailed(let e):
                return "helper spawn failed: \(e)"
            case .unsigned:
                return "this copy of Claudette is not signed with a certificate, so the update could not be verified"
            }
        }
    }

    /// Download the DMG, stage the helper, terminate Claudette. The helper
    /// then replaces the bundle and relaunches it.
    static func run(dmgURL: URL) async {
        do {
            try await runInternal(dmgURL: dmgURL)
        } catch {
            await notifyError(error)
        }
    }

    private static func runInternal(dmgURL: URL) async throws {
        // 1. Locate our own bundle. Refuse to update a non,bundled binary
        //    (the dev SPM build) or one launched read,only (translocated DMG).
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { throw UpdateError.notInBundle }

        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw UpdateError.bundleNotWritable
        }
        guard let requirement = designatedRequirement() else {
            throw UpdateError.unsigned
        }

        // 2. Staging directory.
        let tmpDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("claudette-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true
        )

        // 3. Download the DMG.
        let dmgPath = (tmpDir as NSString).appendingPathComponent("Claudette.dmg")
        let (downloaded, response) = try await URLSession.shared.download(from: dmgURL)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw UpdateError.downloadFailed(status) }
        try FileManager.default.moveItem(
            at: downloaded, to: URL(fileURLWithPath: dmgPath)
        )

        // 4. Write the helper script.
        let scriptPath = (tmpDir as NSString).appendingPathComponent("install.sh")
        let script = SelfUpdateScript.make(
            bundlePath: bundlePath,
            dmgPath: dmgPath,
            workDir: tmpDir,
            pid: ProcessInfo.processInfo.processIdentifier,
            requirement: requirement
        )
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            guard chmod(scriptPath, 0o755) == 0 else { throw UpdateError.writeFailed }
        } catch UpdateError.writeFailed {
            throw UpdateError.writeFailed
        } catch {
            throw UpdateError.writeFailed
        }

        // 5. Spawn the helper, detached. Foundation's Process reparents the
        //    child to launchd when we terminate, so it keeps running.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [scriptPath]
        p.standardInput = nil
        p.standardOutput = nil
        p.standardError = nil
        do {
            try p.run()
        } catch {
            throw UpdateError.spawnFailed(error)
        }

        // 6. Quit. The helper takes it from here.
        NSApp.terminate(nil)
    }

    /// The running app's designated requirement: its bundle id and the
    /// certificate it is signed with. Nil for an unsigned or ad hoc build,
    /// which then cannot update itself.
    static func designatedRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return nil }
        let string = text as String
        // Ad hoc signatures only pin their own hash: no update could match.
        return string.contains("cdhash") ? nil : string
    }

    /// Surface an error via AppleScript `display notification` (no UN
    /// dependency: we may be in a state where UN is unreliable).
    private static func notifyError(_ error: Error) async {
        let body = "Update failed: \(error)"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let src = """
        display notification "\(body)" with title "Claudette" sound name "Basso"
        """
        var ns: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&ns)
    }
}
