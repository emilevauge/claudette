import Foundation
import Darwin

/// Sessions that publish no state file.
///
/// Claude Code writes `~/.claude/sessions/<pid>.json` for every interactive
/// session, but only while session persistence is on. A session that
/// inherited the `CLAUDE_CODE_CHILD_SESSION` marker (typically one started
/// from inside another session) runs with persistence off: no JSON, no
/// transcript on disk, only the IPC key
/// `~/.claude/sessions/<pid>.<hash>.key`. Such a session used to be missing
/// from the list entirely, which reads as "Claudette is broken" rather than
/// "this session doesn't publish anything".
///
/// So we rebuild what the key still allows: the pid from the file name, the
/// start time from its payload, the working directory from the process
/// itself. Everything else is absent by construction : no session id, so no
/// aiTitle, no context gauge and no history entry when it ends, and no
/// `status` field, so the phase falls back to the terminal title the way it
/// already does whenever the field is missing.
enum SessionKeys {

    /// One `<pid>.<hash>.key` file, parsed.
    struct Key {
        let pid: Int32
        let startedAt: Date
    }

    /// Every key file in `dir`, ignoring the ones we can't parse. The caller
    /// filters out dead pids and the ones a JSON already covers.
    static func scan(dir: String) -> [Key] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return []
        }
        return names.compactMap { name in
            guard name.hasSuffix(".key"),
                  let pid = name.split(separator: ".").first.flatMap({ Int32($0) }) else {
                return nil
            }
            return Key(pid: pid, startedAt: startDate(atPath: "\(dir)/\(name)") ?? Date())
        }
    }

    /// Working directory of a running process, read straight from the kernel.
    /// No spawn, no permission beyond owning the process, so this is cheap
    /// enough for the poll loop.
    static func cwd(ofPid pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == Int32(size) else {
            return nil
        }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.isEmpty ? nil : path
    }

    /// `procStart` out of the key payload, e.g. `Fri Sep 18 07:42:39 2026`.
    /// It is written in UTC with a C-locale weekday and month, hence the
    /// fixed locale and time zone. Falls back to `nil` so the caller can use
    /// the file's own date rather than show a session as starting in 1970.
    private static func startDate(atPath path: String) -> Date? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = raw["procStart"] as? String else {
            return nil
        }
        return startFormatter.date(from: text)
    }

    private static let startFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()
}
