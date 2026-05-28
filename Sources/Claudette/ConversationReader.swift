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

    /// True iff a background task (a subagent or a `Bash` with
    /// `run_in_background: true`) is currently writing output for this
    /// session. Claude Code does NOT keep the session JSON `status`
    /// field at "busy" while these run : `status` flips to "idle" or
    /// "shell" as soon as the main turn ends, even when a 25-minute
    /// `go test` is still running detached.
    ///
    /// The signal we use is the mtime of `*.output` files under
    /// `/tmp/claude-<uid>/<cwd-slug>/<harness-id>/tasks/`. The harness
    /// writes background tool stdout there as it streams, so a
    /// recently-modified file means the task is still producing output.
    /// We deliberately do NOT scan the JSONL transcript : Claude Code
    /// emits the `tool_result` for these tools immediately on launch
    /// (with just a task ID), not on completion, so every background
    /// `tool_use` appears resolved in the JSONL the moment it's issued.
    ///
    /// Limitations : a background bash that pauses for more than
    /// `staleThreshold` seconds (a slow compile, an API call) gets
    /// missed until output resumes. Acceptable trade-off : during such
    /// pauses there's nothing to show anyway, and the alternative
    /// (process-table inspection) is much heavier to do every 2 s.
    static func hasBackgroundWork(for session: ClaudeSession,
                                  staleThreshold: TimeInterval = 5.0) -> Bool {
        let slug = projectSlug(for: session.cwd)
        let root = "/tmp/claude-\(getuid())/\(slug)"
        let fm = FileManager.default
        guard let harnessDirs = try? fm.contentsOfDirectory(atPath: root) else {
            return false
        }
        let now = Date().timeIntervalSince1970
        for harnessDir in harnessDirs {
            let tasksDir = "\(root)/\(harnessDir)/tasks"
            guard let entries = try? fm.contentsOfDirectory(atPath: tasksDir) else {
                continue
            }
            for entry in entries where entry.hasSuffix(".output") {
                let filePath = "\(tasksDir)/\(entry)"
                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mdate = attrs[.modificationDate] as? Date else {
                    continue
                }
                if now - mdate.timeIntervalSince1970 < staleThreshold {
                    return true
                }
            }
        }
        return false
    }

    /// List of subagents currently writing to their transcript. Each
    /// session's `Agent` tool invocations create
    /// `~/.claude/projects/<slug>/<sessionId>/subagents/agent-<hash>.jsonl`
    /// (the transcript) plus a sibling `agent-<hash>.meta.json` carrying
    /// `agentType` and `description`. The transcript file is appended
    /// to while the subagent runs and gets a final assistant entry with
    /// `stop_reason: "end_turn"` (or `stop_sequence`) when it returns.
    ///
    /// Two-tier liveness check :
    ///  - **Fast path** : mtime within `recentMtimeWindow` (5 s)
    ///    → certainly still writing, no I/O needed beyond `stat`.
    ///  - **Slow path** : mtime older than that → tail-read the last
    ///    16 KB and look at the most recent `assistant` entry's
    ///    `stop_reason`. `end_turn` / `stop_sequence` means the agent
    ///    has reported a clean completion ; anything else (or no
    ///    assistant entry in the tail at all) means it's still alive
    ///    (between tool calls, deep in thinking, etc.). A subagent
    ///    thinking for 30+ seconds without writing therefore stays
    ///    counted, instead of flickering out of the UI.
    ///  - **Absolute staleness** : files untouched for more than
    ///    `absoluteStaleness` (1 h) are skipped without reading, in
    ///    case a long-dead agent never wrote a completion marker (the
    ///    process was killed, the machine slept, ...) and would
    ///    otherwise linger forever.
    static func activeSubagents(for session: ClaudeSession) -> [ActiveSubagent] {
        let slug = projectSlug(for: session.cwd)
        let dir = "\(NSHomeDirectory())/.claude/projects/\(slug)/\(session.sessionId)/subagents"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        let now = Date().timeIntervalSince1970
        let recentMtimeWindow: TimeInterval = 5.0
        let absoluteStaleness: TimeInterval = 3600.0
        var result: [ActiveSubagent] = []

        for entry in entries where entry.hasSuffix(".jsonl") {
            let jsonlPath = "\(dir)/\(entry)"
            guard let attrs = try? fm.attributesOfItem(atPath: jsonlPath),
                  let mdate = attrs[.modificationDate] as? Date else { continue }
            let age = now - mdate.timeIntervalSince1970

            if age > absoluteStaleness { continue }
            if age >= recentMtimeWindow {
                // Slow path : if the tail shows a clean completion we
                // skip this agent ; otherwise we keep it as active.
                // Mtime-keyed cache : as long as the file isn't being
                // written to, the answer doesn't change, so we never
                // re-tail-read once we've determined an agent is done.
                // Critical for sessions that accumulate dozens of
                // historical subagents (the security-advisor pipeline
                // and similar) — otherwise every refresh re-reads
                // 16 KB per agent and blocks the UI.
                let mtime = mdate.timeIntervalSince1970
                let completed: Bool
                if let cached = subagentCompletionCache.value(for: jsonlPath,
                                                              mtime: mtime) {
                    completed = cached
                } else {
                    completed = subagentHasCompleted(at: jsonlPath)
                    subagentCompletionCache.set(path: jsonlPath,
                                                mtime: mtime,
                                                completed: completed)
                }
                if completed { continue }
            }

            // Pair with the meta.json. Falls back to a generic
            // "agent" / empty description if the meta is missing or unreadable.
            let metaPath = jsonlPath.replacingOccurrences(of: ".jsonl",
                                                          with: ".meta.json")
            var agentType = "agent"
            var description = ""
            if let metaData = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
               let obj = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
                agentType = (obj["agentType"] as? String) ?? agentType
                description = (obj["description"] as? String) ?? description
            }
            result.append(ActiveSubagent(agentType: agentType,
                                         description: description))
        }
        return result
    }

    /// Tail-read the last 16 KB of a subagent's JSONL and return true
    /// iff the most recent `assistant` entry has a `stop_reason` of
    /// `end_turn` or `stop_sequence` (a clean completion). Returns
    /// false when no assistant entry is found in the tail (still
    /// thinking or mid tool-call), when the file can't be opened, or
    /// when the JSON is unparseable.
    private static func subagentHasCompleted(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        let size: UInt64
        do { size = try handle.seekToEnd() } catch { return false }
        if size == 0 { return false }

        // 16 KB tail is plenty : the final assistant turn (often a
        // short text plus end_turn marker) fits in a few KB. We don't
        // grow the window beyond that because the slow path is hit on
        // every refresh for every quiet subagent, and the answer is
        // either "right at the end" or doesn't matter (we'd default
        // to active = keep showing).
        let window: UInt64 = 16 * 1024
        let from = size > window ? size - window : 0
        do { try handle.seek(toOffset: from) } catch { return false }
        let data: Data = (try? handle.readToEnd()) ?? Data()

        var slice = data[...]
        if from > 0, let nl = slice.firstIndex(of: 0x0A) {
            slice = slice[(nl + 1)...]
        }
        guard let content = String(data: Data(slice), encoding: .utf8) else { return false }

        for line in content.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let bytes = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let stop = msg["stop_reason"] as? String
            else { continue }
            return stop == "end_turn" || stop == "stop_sequence"
        }
        return false
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

    /// Same idea, for the subagent transcript completion check. Key is
    /// the absolute jsonl path. Once we've confirmed an agent ended
    /// cleanly (or hasn't), the answer stays the same until the file
    /// is appended to again, which changes its mtime and invalidates
    /// the entry. Cuts the tail-read cost on heavy sessions to ~zero
    /// after the first refresh.
    private final class SubagentCompletionCache: @unchecked Sendable {
        struct Entry { let mtime: TimeInterval; let completed: Bool }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func value(for path: String, mtime: TimeInterval) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[path], e.mtime == mtime else { return nil }
            return e.completed
        }
        func set(path: String, mtime: TimeInterval, completed: Bool) {
            lock.lock(); defer { lock.unlock() }
            entries[path] = Entry(mtime: mtime, completed: completed)
        }
    }
    private static let subagentCompletionCache = SubagentCompletionCache()

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
