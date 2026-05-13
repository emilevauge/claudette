import Foundation
import AppKit

/// Self,update flow triggered from the "Update" notification action.
///
/// The app cannot rewrite its own bundle while running (binary is locked),
/// so we stage a helper shell script in a tmp dir, spawn it detached, then
/// terminate ourselves. The script waits for our PID to exit, mounts the
/// DMG, replaces the bundle in place, strips the quarantine xattr, and
/// relaunches Claudette.
@MainActor
enum SelfUpdater {

    enum UpdateError: Error, CustomStringConvertible {
        case notInBundle
        case bundleNotWritable
        case downloadFailed(Int?)
        case writeFailed
        case spawnFailed(Error)

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
        let mountPath = (tmpDir as NSString).appendingPathComponent("mount")
        let scriptPath = (tmpDir as NSString).appendingPathComponent("install.sh")
        let logPath = (tmpDir as NSString).appendingPathComponent("install.log")
        let pid = ProcessInfo.processInfo.processIdentifier
        let backupPath = bundlePath + ".claudette-update-backup"
        let script = """
        #!/bin/zsh
        set -eu
        exec >\(shellQuote(logPath)) 2>&1

        BUNDLE=\(shellQuote(bundlePath))
        BACKUP=\(shellQuote(backupPath))
        MOUNT=\(shellQuote(mountPath))
        DMG=\(shellQuote(dmgPath))
        TMP=\(shellQuote(tmpDir))

        # Wait for Claudette (pid \(pid)) to exit, up to 10 s.
        for _ in {1..100}; do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.1
        done

        mkdir -p "$MOUNT"
        hdiutil attach -nobrowse -mountpoint "$MOUNT" "$DMG"

        # Refuse to destroy the bundle if the DMG content is bad.
        if [ ! -d "$MOUNT/Claudette.app" ]; then
            hdiutil detach "$MOUNT" || true
            echo "Bad DMG: missing Claudette.app inside" >&2
            exit 1
        fi

        # Atomic,ish swap: move the old bundle aside, copy the new one in.
        # If cp fails, restore from backup so the user is never appless.
        rm -rf "$BACKUP"
        mv "$BUNDLE" "$BACKUP"
        if cp -R "$MOUNT/Claudette.app" "$BUNDLE"; then
            rm -rf "$BACKUP"
        else
            rm -rf "$BUNDLE"
            mv "$BACKUP" "$BUNDLE"
            hdiutil detach "$MOUNT" || true
            echo "cp failed, rolled back" >&2
            exit 1
        fi

        # Some nested resource files are mode 444; xattr noisily fails on
        # those even though the bundle root flag is what Gatekeeper checks.
        xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
        hdiutil detach "$MOUNT" || true
        open "$BUNDLE"
        rm -rf "$TMP"
        """
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

    /// POSIX shell single,quote escaping: wrap in '...', escape embedded
    /// quotes by closing, escaping, and reopening.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
