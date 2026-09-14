import Foundation
import Combine
import Darwin
import AppKit

/// Watches `~/.claude/sessions/*.json` and publishes sessions whose PID is alive.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Sessions closed within the retention window (7 days by default, see
    /// `HistoryRetention`), most recently
    /// ended first. Rendered greyed out under the live ones; clicking one
    /// reopens it with `claude --resume`.
    @Published private(set) var history: [ClosedSession] = []

    /// Called every time a session transitions from busy to non-busy.
    var onSessionBecameIdle: ((ClaudeSession) -> Void)?

    private var timer: Timer?
    private let sessionsDir: String
    private let pollInterval: TimeInterval

    /// Persistent archive of closed sessions.
    private let historyStore = SessionHistoryStore()

    /// Last live snapshot of each session, keyed by `sessionId`. Claude Code
    /// usually leaves `~/.claude/sessions/<pid>.json` behind after the process
    /// exits (so a dead PID is enough to detect the close), but it also prunes
    /// those files eventually. Keeping the last snapshot lets us archive a
    /// session whose JSON vanished outright between two polls.
    private var lastSeenAlive: [String: ClaudeSession] = [:]

    /// Retention the transcript backfill last ran for, in days. Zero until it
    /// has run. Widening the window in the settings panel brings older
    /// transcripts into range, so the backfill runs again; narrowing it only
    /// needs the prune, which happens on every refresh.
    private var backfilledForDays = 0

    /// Raw `status` field of each session at the previous refresh
    /// (sessionId → status). We trigger the "session became idle"
    /// notification only when the raw status field transitions from
    /// `"busy"` to anything else, not when our derived `phase` toggles.
    /// `hasBackgroundWork` (per the `/tmp/claude-<uid>/.../tasks/*.output`
    /// mtime heuristic) flickers as subagents pause writing between
    /// tool calls ; firing notifications off that produced a spurious
    /// "Claude is waiting for input" alert every time a background
    /// burst dipped for more than 5 seconds.
    private var previousStatus: [String: String] = [:]
    /// First refresh: don't emit transitions on cold start.
    private var hasBootstrapped = false

    init(pollInterval: TimeInterval = 2.0) {
        self.sessionsDir = "\(NSHomeDirectory())/.claude/sessions"
        self.pollInterval = pollInterval
    }

    func start() {
        guard timer == nil else { return }
        // Surface the Accessibility prompt once. Granting it lets the poll
        // loop read Ghostty titles via the (cheap) Accessibility API instead
        // of an Apple Event round-trip ; until then we transparently fall
        // back to AppleScript.
        GhosttyBridge.ensureAccessibilityPermission(prompt: true)
        refresh()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            sessions = []
            return
        }

        var alive: [ClaudeSession] = []
        historyStore.prune()
        var seenIds = Set<String>()
        for name in names where name.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(name)"
            guard var session = Self.parse(path: path) else { continue }
            // Skip headless SDK invocations: `claude -p ...`, programmatic
            // subagents and any other non,interactive call. They write the
            // same session JSON as a real CLI session, so without this
            // filter we show a phantom "duplicate" row in the same cwd as
            // the real `cli` session that spawned them.
            if session.entrypoint == "sdk-cli" { continue }
            seenIds.insert(session.sessionId)
            // Dead PID: the session is over, archive the snapshot its JSON
            // still holds.
            guard Self.isAlive(pid: session.pid) else {
                historyStore.record(session)
                continue
            }
            session.aiTitle = ConversationReader.aiTitle(for: session)
            session.contextFraction = ConversationReader.contextFraction(for: session)
            session.hasBackgroundWork = ConversationReader.hasBackgroundWork(for: session)
            session.activeSubagents = ConversationReader.activeSubagents(for: session)
            alive.append(session)
        }

        // Sessions whose JSON disappeared since the last poll: archive the
        // snapshot we still have in memory.
        let aliveIds = Set(alive.map(\.sessionId))
        for (id, snapshot) in lastSeenAlive where !seenIds.contains(id) {
            historyStore.record(snapshot)
        }
        lastSeenAlive = alive.reduce(into: [String: ClaudeSession]()) { acc, s in
            if !s.sessionId.isEmpty { acc[s.sessionId] = s }
        }

        // Seed the archive from the transcripts on disk, so sessions closed
        // while Claudette wasn't running still show up. Runs on the first
        // refresh, then again whenever the retention window is widened.
        if HistoryRetention.days > backfilledForDays {
            backfilledForDays = HistoryRetention.days
            historyStore.backfillFromTranscripts(excluding: aliveIds)
        }

        // A session id can come back from the dead (`claude --resume` keeps
        // it), so never show the same session in both lists.
        let closed = historyStore.sorted.filter { !aliveIds.contains($0.sessionId) }
        if closed != history { history = closed }
        historyStore.flushIfNeeded()

        // Annotate with the matching Ghostty terminal: its title reflects the
        // real state of Claude (spinner glyph / ✳) in real time. Skip the
        // enumeration entirely when there are no alive sessions to annotate.
        // `listTerminals()` uses the Accessibility API on the hot path, so
        // this is cheap enough to run every poll.
        let terminals = (alive.isEmpty || !ghosttyIsRunning())
            ? []
            : GhosttyBridge.listTerminals()
        if !terminals.isEmpty {
            alive = Self.annotate(alive, with: terminals)
        }

        // Sort: busy first, then most recently updated.
        alive.sort { a, b in
            if a.isBusy != b.isBusy { return a.isBusy }
            return a.updatedAt > b.updatedAt
        }

        // Detect `status: "busy"` → non-busy transitions on the raw
        // session JSON field, not on our derived `phase`. The phase
        // includes the `hasBackgroundWork` override which flickers as
        // background subagents pause between writes ; basing
        // notifications on it produced spurious alerts for sessions
        // doing bursty parallel work. We notify when the actual main
        // loop reports completion (status flips to `idle`, `waiting`
        // or `shell`) and ignore the background-work flickering.
        if hasBootstrapped {
            for s in alive {
                let prev = previousStatus[s.id] ?? ""
                if prev == "busy", s.status != "busy", !s.status.isEmpty {
                    onSessionBecameIdle?(s)
                }
            }
        }
        // Two sessions can collide on `id` (sessionId reused across PIDs
        // when the harness restarts, sdk-cli forks, or the field is empty
        // and we fall back to PID for two distinct rows). `uniqueKeysWith,
        // Values:` traps on duplicates, so dedupe explicitly: keep `busy`
        // when present so we don't drop a busy,>idle transition on the
        // next refresh.
        previousStatus = alive.reduce(into: [String: String]()) { acc, s in
            if acc[s.id] != "busy" { acc[s.id] = s.status }
        }
        hasBootstrapped = true

        sessions = alive
    }

    /// Drop one closed session from the history (user action).
    func forget(_ closed: ClosedSession) {
        historyStore.forget(sessionId: closed.sessionId)
        historyStore.flushIfNeeded()
        history.removeAll { $0.sessionId == closed.sessionId }
    }

    /// Drop the whole history (user action).
    func clearHistory() {
        historyStore.forgetAll()
        historyStore.flushIfNeeded()
        history = []
    }

    private func ghosttyIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" })
    }

    /// Map each session to at most one Ghostty terminal, and each terminal to
    /// at most one session.
    ///
    /// The one,to,one part matters: matching each session independently made
    /// two sessions in the same directory both settle on the same terminal
    /// (the first cwd match), so they showed the same busy state and the same
    /// row click focused the same tab. Terminals are claimed as they are
    /// assigned, and the deterministic pass runs before the fuzzy one so a
    /// weak cwd match can never steal a terminal an aiTitle match needs.
    ///
    /// Pass 1 : exact `aiTitle` match. Claude Code injects `<glyph> <aiTitle>`
    ///   into the tab title verbatim, and the aiTitle is unique per session,
    ///   so this is collision,free.
    /// Pass 2 : match on normalized cwd, preferring terminals that actually
    ///   run Claude (glyph,prefixed title) over plain shells parked in the
    ///   same directory, then those whose title contains the session `name`.
    /// Pass 3 : no cwd match at all : any unclaimed Claude terminal whose
    ///   title contains the session `name`.
    private static func annotate(
        _ sessions: [ClaudeSession],
        with terminals: [GhosttyBridge.GhosttyTerminal]
    ) -> [ClaudeSession] {
        // Claude Desktop agents have no terminal of their own; skip matching.
        let matchable = sessions.indices.filter { !sessions[$0].isClaudeDesktop }
        var result = sessions
        var claimed = Set<Int>()

        func claim(_ sessionIndex: Int, _ terminalIndex: Int) {
            claimed.insert(terminalIndex)
            result[sessionIndex].terminalTitle = terminals[terminalIndex].name
            result[sessionIndex].terminalId = terminals[terminalIndex].id
        }

        func firstUnclaimed(
            _ candidates: [Int],
            where predicate: (GhosttyBridge.GhosttyTerminal) -> Bool
        ) -> Int? {
            candidates.first { !claimed.contains($0) && predicate(terminals[$0]) }
        }

        let all = Array(terminals.indices)

        // Pass 1: deterministic, so it gets first pick of the terminals.
        var unmatched: [Int] = []
        for i in matchable {
            guard let aiTitle = result[i].aiTitle, !aiTitle.isEmpty,
                  let t = firstUnclaimed(all, where: {
                      ClaudeTitle.matches(title: $0.name, aiTitle: aiTitle)
                  }) else {
                unmatched.append(i)
                continue
            }
            claim(i, t)
        }

        // Pass 2 and 3: heuristics, on whatever terminals are left.
        for i in unmatched {
            let session = result[i]
            let needle = (session.name?.isEmpty == false) ? session.name! : session.windowSearchKey
            let sessionCwd = normalize(session.cwd)

            let byCwd = all.filter { normalize(terminals[$0].cwd) == sessionCwd }
            let claudeOnly = byCwd.filter { ClaudeTitle.isClaudeTerminal(title: terminals[$0].name) }
            let pool = claudeOnly.isEmpty ? byCwd : claudeOnly

            let chosen = firstUnclaimed(pool, where: { $0.name.contains(needle) })
                ?? firstUnclaimed(pool, where: { _ in true })
                ?? firstUnclaimed(all, where: {
                    !needle.isEmpty && $0.name.contains(needle)
                        && ClaudeTitle.isClaudeTerminal(title: $0.name)
                })

            if let t = chosen { claim(i, t) }
        }

        return result
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func parse(path: String) -> ClaudeSession? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (raw["pid"] as? Int).map(Int32.init) else {
            return nil
        }
        let startedMs = (raw["startedAt"] as? Double) ?? 0
        let updatedMs = (raw["updatedAt"] as? Double) ?? startedMs
        return ClaudeSession(
            pid: pid,
            sessionId: raw["sessionId"] as? String ?? "",
            cwd: raw["cwd"] as? String ?? "",
            startedAt: Date(timeIntervalSince1970: startedMs / 1000),
            updatedAt: Date(timeIntervalSince1970: updatedMs / 1000),
            version: raw["version"] as? String ?? "",
            status: raw["status"] as? String ?? "",
            kind: raw["kind"] as? String ?? "",
            entrypoint: raw["entrypoint"] as? String ?? "",
            name: raw["name"] as? String,
            bridgeSessionId: raw["bridgeSessionId"] as? String
        )
    }

    /// `kill(pid, 0)` doesn't kill anything: it only checks that the process
    /// exists and is reachable by the current user.
    private static func isAlive(pid: Int32) -> Bool {
        return kill(pid, 0) == 0
    }
}
