import Foundation

/// Reads a Claude Code session's JSONL transcript to extract the last
/// non-empty assistant message. File path:
/// `~/.claude/projects/<slug>/<sessionId>.jsonl`.
enum ConversationReader {

    /// Return the last text produced by Claude in this session.
    /// `nil` if the file is missing, unreadable, or contains no text block.
    static func lastAssistantText(for session: ClaudeSession) -> String? {
        let slug = projectSlug(for: session.cwd)
        let path = "\(NSHomeDirectory())/.claude/projects/\(slug)/\(session.sessionId).jsonl"

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Iterate lines in reverse, return the first non-sidechain assistant
        // message that contains at least one non-empty text block.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let bytes = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else {
                continue
            }

            if let blocks = message["content"] as? [[String: Any]] {
                let texts = blocks.compactMap { b -> String? in
                    guard b["type"] as? String == "text",
                          let t = b["text"] as? String,
                          !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    return t
                }
                let joined = texts.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            } else if let str = message["content"] as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Return the latest LLM,generated title for this session, or `nil` if
    /// none has been produced yet (very short sessions, or sessions whose
    /// JSON already carries an explicit `name`, in which case Claude Code
    /// skips title generation).
    ///
    /// The transcript contains zero or more `{"type":"ai-title","aiTitle":"..."}`
    /// entries; we keep the last one. Results are cached by file mtime so
    /// re,reading the same unchanged transcript on each refresh is cheap.
    static func aiTitle(for session: ClaudeSession) -> String? {
        // Short,circuit: an explicit session name means Claude Code does not
        // emit ai,title entries. Spares us reading a potentially huge JSONL
        // on every refresh (long sessions can be hundreds of MB).
        if let n = session.name, !n.isEmpty { return nil }

        let path = transcriptPath(for: session)
        let mtime = mtimeOf(path)

        if let cached = cache.value(for: session.sessionId), cached.mtime == mtime {
            return cached.title
        }

        let title = mtime == nil ? nil : readAiTitle(from: path)
        cache.set(sessionId: session.sessionId, mtime: mtime, title: title)
        return title
    }

    /// True iff the JSONL transcript's tail shows Claude is blocked waiting
    /// for the user. The signal : the latest non-sidechain `assistant`
    /// message has a `tool_use` block whose `tool_use_id` has no matching
    /// `tool_result` yet. `AskUserQuestion` always counts; other tools
    /// (Bash, Read, ...) only count if the entry is older than
    /// `permissionPromptAgeSeconds`, otherwise the tool is most likely
    /// still auto-running.
    ///
    /// We need this because Claude Code (>= v2.1.141) sometimes leaves
    /// `~/.claude/sessions/<pid>.json` at `status: "busy"` while the CLI
    /// is actually showing an `AskUserQuestion` UI or a permission prompt,
    /// so the session.json alone misclassifies these as "thinking".
    static func isBlockedOnUser(for session: ClaudeSession,
                                permissionPromptAgeSeconds: Double = 5.0) -> Bool {
        let path = transcriptPath(for: session)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // No mtime cache : the age threshold depends on wall-clock time,
        // not just file content, so a stale "no, tool too young" cached
        // entry would never flip to "yes" even after the tool ages past
        // the threshold (the JSONL is by definition not being written
        // during a permission prompt). 64 KB scan every 2 s is cheap.
        return scanBlockedOnUser(path: path,
                                 ageThreshold: permissionPromptAgeSeconds)
    }

    private static func scanBlockedOnUser(path: String,
                                          ageThreshold: Double) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        let size: UInt64
        do { size = try handle.seekToEnd() } catch { return false }
        if size == 0 { return false }

        // Same exponential tail strategy as the ai-title reader : 64 KB
        // is enough for the latest few turns; expand up to 4 MB only when
        // we couldn't find a discriminating entry.
        var window: UInt64 = 64 * 1024
        let maxWindow: UInt64 = 4 * 1024 * 1024

        while true {
            let from = size > window ? size - window : 0
            do { try handle.seek(toOffset: from) } catch { return false }
            let data: Data = (try? handle.readToEnd()) ?? Data()

            var slice = data[...]
            if from > 0, let nl = slice.firstIndex(of: 0x0A) {
                slice = slice[(nl + 1)...]
            }

            if let decided = decideBlockedOnUser(in: Data(slice),
                                                  ageThreshold: ageThreshold) {
                return decided
            }

            if from == 0 || window >= maxWindow { return false }
            window = min(window * 4, maxWindow)
        }
    }

    /// Walks lines in reverse, collecting `tool_result.tool_use_id`s along
    /// the way. The first non-sidechain `assistant` we hit decides :
    ///  - `stop_reason == "tool_use"` and any of its `tool_use` blocks has
    ///    no matching `tool_result` in `seenIds` → pending tool. If the
    ///    pending tool is `AskUserQuestion`, or if the entry is older than
    ///    `ageThreshold`, treat as blocked on user.
    ///  - `stop_reason in {end_turn, stop_sequence}` → not blocked.
    ///  - all tool_use ids already resolved → Claude is composing the
    ///    follow-up, not blocked.
    ///
    /// Returns `nil` when the slice contains no assistant entry; the caller
    /// expands the window.
    private static func decideBlockedOnUser(in data: Data,
                                             ageThreshold: Double) -> Bool? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var seenToolResultIds = Set<String>()

        for line in lines.reversed() {
            guard let bytes = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            else { continue }
            let type = obj["type"] as? String

            // Collect tool_result ids from user entries that appear AFTER
            // the next assistant entry we'll find (we walk reversed, so we
            // see "later" entries first).
            if type == "user", let msg = obj["message"] as? [String: Any],
               let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "tool_result" {
                    if let id = b["tool_use_id"] as? String {
                        seenToolResultIds.insert(id)
                    }
                }
                continue
            }

            guard type == "assistant",
                  obj["isSidechain"] as? Bool != true,
                  let msg = obj["message"] as? [String: Any] else {
                continue
            }

            switch msg["stop_reason"] as? String {
            case "tool_use":
                guard let blocks = msg["content"] as? [[String: Any]] else {
                    return false
                }
                let pending = blocks.compactMap { b -> (name: String, id: String)? in
                    guard b["type"] as? String == "tool_use",
                          let id = b["id"] as? String,
                          !seenToolResultIds.contains(id) else { return nil }
                    let name = (b["name"] as? String) ?? ""
                    return (name, id)
                }
                if pending.isEmpty { return false }

                if pending.contains(where: { $0.name == "AskUserQuestion" }) {
                    return true
                }
                if let ts = obj["timestamp"] as? String,
                   let date = iso.date(from: ts),
                   -date.timeIntervalSinceNow > ageThreshold {
                    return true
                }
                return false

            case "end_turn", "stop_sequence":
                return false

            default:
                continue
            }
        }
        return nil
    }

    /// Read the context window fill ratio (0..1) from the per,session
    /// sidecar that the user's status,line command exposes at
    /// `/tmp/claudette/<sessionId>.json`. The JSON layout is what Claude
    /// Code itself feeds to the status line, and includes a precomputed
    /// `context_window.used_percentage`. Returns `nil` when the sidecar
    /// is missing (status line not yet invoked for this session, or not
    /// configured to write the sidecar).
    static func contextFraction(for session: ClaudeSession) -> Double? {
        let path = "/tmp/claudette/\(session.sessionId).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cw = obj["context_window"] as? [String: Any],
              let pct = cw["used_percentage"] as? Double else {
            return nil
        }
        return max(0, min(1, pct / 100.0))
    }

    private static func transcriptPath(for session: ClaudeSession) -> String {
        let slug = projectSlug(for: session.cwd)
        return "\(NSHomeDirectory())/.claude/projects/\(slug)/\(session.sessionId).jsonl"
    }

    private static func mtimeOf(_ path: String) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970
    }

    /// Tail,read strategy: JSONL transcripts can grow to hundreds of MB on
    /// long sessions, but Claude re,emits `ai-title` entries regularly. Read
    /// the last 64 KB and expand exponentially up to 4 MB if no entry is
    /// found, instead of loading the whole file each refresh.
    private static func readAiTitle(from path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let size: UInt64
        do { size = try handle.seekToEnd() } catch { return nil }
        if size == 0 { return nil }

        var window: UInt64 = 64 * 1024
        let maxWindow: UInt64 = 4 * 1024 * 1024

        while true {
            let from = size > window ? size - window : 0
            do { try handle.seek(toOffset: from) } catch { return nil }
            let data: Data
            do { data = (try handle.readToEnd()) ?? Data() } catch { return nil }

            // When the window starts mid,file, the first partial line (and any
            // UTF,8 boundary cut) is dropped by skipping to the first newline.
            var slice = data[...]
            if from > 0, let nl = slice.firstIndex(of: 0x0A) {
                slice = slice[(nl + 1)...]
            }

            if let title = lastAiTitleEntry(in: Data(slice)) {
                return title
            }

            if from == 0 || window >= maxWindow { return nil }
            window = min(window * 4, maxWindow)
        }
    }

    private static func lastAiTitleEntry(in data: Data) -> String? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let bytes = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  obj["type"] as? String == "ai-title",
                  let t = (obj["aiTitle"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else {
                continue
            }
            return t
        }
        return nil
    }

    /// Thread,safe cache keyed by sessionId, invalidated by file mtime.
    /// Accessed from SessionStore on @MainActor, but we keep the lock so the
    /// type stays safe to call from anywhere.
    private final class AiTitleCache: @unchecked Sendable {
        struct Entry { let mtime: TimeInterval?; let title: String? }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func value(for sessionId: String) -> Entry? {
            lock.lock(); defer { lock.unlock() }
            return entries[sessionId]
        }
        func set(sessionId: String, mtime: TimeInterval?, title: String?) {
            lock.lock(); defer { lock.unlock() }
            entries[sessionId] = Entry(mtime: mtime, title: title)
        }
    }
    private static let cache = AiTitleCache()

    /// Project path encoding used by Claude Code: every non-alphanumeric
    /// character is replaced by '-' (two consecutive non-alnum characters
    /// yield '--').
    static func projectSlug(for path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count)
        for scalar in path.unicodeScalars {
            let v = scalar.value
            let isAlnum =
                (0x30...0x39).contains(v) ||
                (0x41...0x5A).contains(v) ||
                (0x61...0x7A).contains(v)
            out.append(isAlnum ? Character(scalar) : "-")
        }
        return out
    }
}
