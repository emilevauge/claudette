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

    /// Detect whether Claude is mid,turn waiting for the user (permission
    /// prompt or `AskUserQuestion`) versus a clean turn end. Returns
    /// `.unknown` when the transcript is missing or the tail doesn't
    /// contain a discriminating entry.
    ///
    /// Algorithm: tail,read the JSONL, walk lines in reverse. The first
    /// "discriminating" entry wins :
    ///   - `system / subtype: turn_duration` → `.idle`
    ///   - `user` with a `tool_result` content block → `.idle` (the result
    ///     just landed; if Claude were responding, the title would say so)
    ///   - `assistant` with `stop_reason: tool_use` → `.needsAttention`
    ///   - `assistant` with `stop_reason: end_turn` / `stop_sequence` → `.idle`
    static func idleKind(for session: ClaudeSession) -> ClaudeSession.IdleKind {
        let path = transcriptPath(for: session)
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        return readIdleKind(from: path)
    }

    private static func readIdleKind(from path: String) -> ClaudeSession.IdleKind {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unknown }
        defer { try? handle.close() }

        let size: UInt64
        do { size = try handle.seekToEnd() } catch { return .unknown }
        if size == 0 { return .unknown }

        // Most "turn boundary" entries (turn_duration, end_turn, tool_use
        // ending an assistant block) are small. 64 KB tail captures the
        // last few turns comfortably. Same exponential strategy as aiTitle.
        var window: UInt64 = 64 * 1024
        let maxWindow: UInt64 = 4 * 1024 * 1024

        while true {
            let from = size > window ? size - window : 0
            do { try handle.seek(toOffset: from) } catch { return .unknown }
            let data: Data = (try? handle.readToEnd()) ?? Data()

            var slice = data[...]
            if from > 0, let nl = slice.firstIndex(of: 0x0A) {
                slice = slice[(nl + 1)...]
            }

            if let kind = lastIdleKind(in: Data(slice)) {
                return kind
            }

            if from == 0 || window >= maxWindow { return .unknown }
            window = min(window * 4, maxWindow)
        }
    }

    private static func lastIdleKind(in data: Data) -> ClaudeSession.IdleKind? {
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        for line in content.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let bytes = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                continue
            }
            let type = obj["type"] as? String

            if type == "system",
               (obj["subtype"] as? String) == "turn_duration" {
                return .idle
            }

            if type == "assistant",
               let msg = obj["message"] as? [String: Any] {
                switch msg["stop_reason"] as? String {
                case "tool_use":
                    return .needsAttention
                case "end_turn", "stop_sequence":
                    return .idle
                default:
                    continue
                }
            }

            if type == "user",
               let msg = obj["message"] as? [String: Any],
               let blocks = msg["content"] as? [[String: Any]],
               blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                // A tool_result just arrived. The title would still be a
                // Braille spinner if Claude were composing a follow,up,
                // so reaching this code means Claude is idle for now.
                return .idle
            }
        }
        return nil
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
