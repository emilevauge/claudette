import Foundation

/// A Claude Code session that has exited, kept around so the user can pick it
/// back up. Fields are a frozen copy of the last live snapshot we saw, plus
/// the moment the session stopped being alive.
struct ClosedSession: Identifiable, Hashable, Codable {
    let sessionId: String
    let cwd: String
    let name: String?
    var aiTitle: String?
    let startedAt: Date
    var endedAt: Date
    let entrypoint: String

    var id: String { sessionId }

    /// Displayed label: explicit name if any, otherwise basename of cwd.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// `claude --resume <id>` replays the JSONL transcript, so a session whose
    /// transcript has been pruned can be listed but not resumed. The row stays
    /// visible and is simply not clickable.
    var isResumable: Bool {
        FileManager.default.fileExists(
            atPath: ConversationReader.transcriptPath(cwd: cwd, sessionId: sessionId)
        )
    }
}

/// How long a closed session stays in the list, in days. User,configurable
/// from the settings panel; `defaultDays` when unset.
enum HistoryRetention {
    static let defaultsKey = "historyRetentionDays"
    static let defaultDays = 7
    static let range = 1...90

    /// Clamped to `range`. A missing or out,of,range value reads as the
    /// default, so a stale or hand,edited preference can't empty the history.
    static var days: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: defaultsKey)
            guard range.contains(stored) else { return defaultDays }
            return stored
        }
        set {
            UserDefaults.standard.set(
                min(max(newValue, range.lowerBound), range.upperBound),
                forKey: defaultsKey
            )
        }
    }

    static var interval: TimeInterval { TimeInterval(days) * 24 * 60 * 60 }
}

/// Keeps the sessions closed within the retention window on disk, so the
/// history survives a Claudette restart (and a Claude Code cleanup of
/// `~/.claude/sessions/*.json`).
///
/// Entries are keyed by `sessionId`. Recording is idempotent: re-recording a
/// session already in the archive only refreshes fields we didn't have yet
/// (a title produced after the last snapshot, a later `endedAt`).
@MainActor
final class SessionHistoryStore {

    /// How long a closed session stays in the list. Read on every use so a
    /// change in the settings panel takes effect on the next poll.
    private var retention: TimeInterval { HistoryRetention.interval }

    private var entries: [String: ClosedSession]
    private let fileURL: URL
    private var dirty = false

    init(fileURL: URL = SessionHistoryStore.defaultURL) {
        self.fileURL = fileURL
        self.entries = Self.read(from: fileURL)
        _ = prune()
    }

    /// Closed sessions, most recently ended first.
    var sorted: [ClosedSession] {
        entries.values.sorted { $0.endedAt > $1.endedAt }
    }

    /// Archive a session we just saw disappear. Returns true when the archive
    /// actually changed, so the caller can skip a disk write and a republish.
    @discardableResult
    func record(_ session: ClaudeSession) -> Bool {
        // Without a sessionId there is nothing to resume, and nothing stable
        // to key on: a PID gets reused.
        guard !session.sessionId.isEmpty else { return false }
        // Headless SDK invocations are filtered out of the live list too.
        guard session.entrypoint != "sdk-cli" else { return false }
        // `updatedAt` is the last activity Claude Code reported, which is as
        // close to "when it ended" as the session JSON gets.
        let endedAt = max(session.updatedAt, session.startedAt)
        guard Date().timeIntervalSince(endedAt) < retention else { return false }

        let title = session.aiTitle ?? ConversationReader.aiTitle(
            cwd: session.cwd, sessionId: session.sessionId
        )

        if var existing = entries[session.sessionId] {
            var changed = false
            if endedAt > existing.endedAt {
                existing.endedAt = endedAt
                changed = true
            }
            if let title, title != existing.aiTitle {
                existing.aiTitle = title
                changed = true
            }
            guard changed else { return false }
            entries[session.sessionId] = existing
            dirty = true
            return true
        }

        entries[session.sessionId] = ClosedSession(
            sessionId: session.sessionId,
            cwd: session.cwd,
            name: session.name,
            aiTitle: title,
            startedAt: session.startedAt,
            endedAt: endedAt,
            entrypoint: session.entrypoint
        )
        dirty = true
        return true
    }

    /// Seed the archive from the JSONL transcripts on disk.
    ///
    /// Claude Code deletes `~/.claude/sessions/<pid>.json` when a session
    /// exits, so watching that directory only catches the sessions that close
    /// while Claudette is running. The transcripts under
    /// `~/.claude/projects/<slug>/<sessionId>.jsonl` are the durable record,
    /// and they are exactly what `claude --resume` replays: one file within
    /// the retention window is one resumable closed session.
    ///
    /// Runs once per launch. `limit` caps the work on a machine with a deep
    /// history; the most recently touched transcripts win.
    func backfillFromTranscripts(excluding liveIds: Set<String>, limit: Int = 200) {
        let fm = FileManager.default
        let root = "\(NSHomeDirectory())/.claude/projects"
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return }
        let cutoff = Date().addingTimeInterval(-retention)

        var candidates: [(sessionId: String, path: String, started: Date, ended: Date)] = []
        for project in projects {
            let dir = "\(root)/\(project)"
            // Only the top level: `<sessionId>/subagents/*.jsonl` holds
            // subagent transcripts, which are not sessions of their own.
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".jsonl") {
                let sessionId = String(file.dropLast(".jsonl".count))
                guard !sessionId.isEmpty,
                      !liveIds.contains(sessionId),
                      entries[sessionId] == nil,
                      let attrs = try? fm.attributesOfItem(atPath: "\(dir)/\(file)"),
                      let ended = attrs[.modificationDate] as? Date,
                      ended >= cutoff else { continue }
                candidates.append((
                    sessionId: sessionId,
                    path: "\(dir)/\(file)",
                    started: (attrs[.creationDate] as? Date) ?? ended,
                    ended: ended
                ))
            }
        }

        candidates.sort { $0.ended > $1.ended }
        for c in candidates.prefix(limit) {
            // No cwd means no way to resume, so nothing worth listing.
            guard let head = ConversationReader.archivedTranscript(at: c.path) else { continue }
            // Headless SDK invocations are filtered out of the live list too.
            if head.entrypoint == "sdk-cli" { continue }
            // The freshest `ai-title` sits near the end of a long transcript ;
            // fall back to whatever the head gave us.
            let title = ConversationReader.archivedAiTitle(cwd: head.cwd, sessionId: c.sessionId)
                ?? head.title
            let started = head.startedAt ?? c.started
            entries[c.sessionId] = ClosedSession(
                sessionId: c.sessionId,
                cwd: head.cwd,
                name: nil,
                aiTitle: title,
                startedAt: min(started, c.ended),
                endedAt: c.ended,
                entrypoint: head.entrypoint ?? "cli"
            )
            dirty = true
        }
    }

    /// Drop everything older than the retention window. Returns true when
    /// something was dropped.
    @discardableResult
    func prune() -> Bool {
        let cutoff = Date().addingTimeInterval(-retention)
        let kept = entries.filter { $0.value.endedAt >= cutoff }
        guard kept.count != entries.count else { return false }
        entries = kept
        dirty = true
        return true
    }

    /// Forget one entry (the user removed it from the list).
    @discardableResult
    func forget(sessionId: String) -> Bool {
        guard entries.removeValue(forKey: sessionId) != nil else { return false }
        dirty = true
        return true
    }

    func forgetAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        dirty = true
    }

    /// Persist, but only when something changed since the last write: the
    /// caller runs on the 2 s poll loop.
    func flushIfNeeded() {
        guard dirty else { return }
        dirty = false
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sorted) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: disk

    nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Claudette", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    nonisolated private static func read(from url: URL) -> [String: ClosedSession] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([ClosedSession].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, b in
            a.endedAt >= b.endedAt ? a : b
        })
    }
}
