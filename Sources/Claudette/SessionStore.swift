import Foundation
import Combine
import Darwin
import AppKit

/// Watches `~/.claude/sessions/*.json` and publishes sessions whose PID is alive.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Called every time a session transitions from busy to non-busy.
    var onSessionBecameIdle: ((ClaudeSession) -> Void)?

    private var timer: Timer?
    private let sessionsDir: String
    private let pollInterval: TimeInterval

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
        for name in names where name.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(name)"
            guard var session = Self.parse(path: path), Self.isAlive(pid: session.pid) else {
                continue
            }
            session.aiTitle = ConversationReader.aiTitle(for: session)
            session.contextFraction = ConversationReader.contextFraction(for: session)
            session.hasBackgroundWork = ConversationReader.hasBackgroundWork(for: session)
            session.activeSubagents = ConversationReader.activeSubagents(for: session)
            alive.append(session)
        }

        // Annotate with the matching Ghostty terminal: its title reflects the
        // real state of Claude (Braille spinner / ✳) in real time.
        let terminals = ghosttyIsRunning() ? GhosttyBridge.listTerminals() : []
        if !terminals.isEmpty {
            alive = alive.map { Self.annotate($0, with: terminals) }
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

    private func ghosttyIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" })
    }

    /// Find the Ghostty terminal matching a session.
    /// 0) if we know the `aiTitle`, match by exact suffix: Claude Code injects
    ///    `<spinner|✳> <aiTitle>` into the tab title verbatim, so this is a
    ///    deterministic match with no false positives.
    /// 1) otherwise, match by normalized cwd.
    /// 2) if several candidates, prefer those whose title starts with a Braille
    ///    spinner (busy) or `✳` (idle): that's a Claude terminal, not a plain
    ///    shell that happens to share the same directory.
    /// 3) among the remaining candidates, prefer the one whose title contains
    ///    the session `name`.
    /// 4) if no cwd match at all, last resort: any terminal whose title
    ///    contains the session name AND looks like a Claude terminal.
    private static func annotate(
        _ session: ClaudeSession,
        with terminals: [GhosttyBridge.GhosttyTerminal]
    ) -> ClaudeSession {
        // Claude Desktop agents have no terminal of their own; skip matching.
        if session.isClaudeDesktop { return session }

        // Step 0: deterministic match via aiTitle when available.
        if let aiTitle = session.aiTitle, !aiTitle.isEmpty,
           let t = terminals.first(where: { titleMatches($0.name, aiTitle: aiTitle) }) {
            var s = session
            s.terminalTitle = t.name
            s.terminalId = t.id
            return s
        }

        let needle = (session.name?.isEmpty == false) ? session.name! : session.windowSearchKey
        let sessionCwd = normalize(session.cwd)

        let byCwd = terminals.filter { normalize($0.cwd) == sessionCwd }
        // Step 2: keep only Claude terminals when we have the choice.
        let claudeCandidates = byCwd.filter(isClaudeTerminal)
        let pool = claudeCandidates.isEmpty ? byCwd : claudeCandidates

        let chosen: GhosttyBridge.GhosttyTerminal? =
            pool.first(where: { $0.name.contains(needle) })
            ?? pool.first
            ?? terminals.first(where: { !needle.isEmpty && $0.name.contains(needle) && isClaudeTerminal($0) })

        guard let t = chosen else { return session }

        var s = session
        s.terminalTitle = t.name
        s.terminalId = t.id
        return s
    }

    /// A Ghostty title matches an aiTitle if, after trimming the leading
    /// Braille spinner or `✳` glyph plus whitespace, it equals the aiTitle.
    /// We tolerate Claude appending a status suffix in the future by using
    /// `hasPrefix` rather than equality.
    private static func titleMatches(_ title: String, aiTitle: String) -> Bool {
        var s = Substring(title)
        if let first = s.unicodeScalars.first,
           (0x2800...0x28FF).contains(first.value) || first.value == 0x2733 {
            s = s.dropFirst()
        }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed == aiTitle || trimmed.hasPrefix(aiTitle)
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// A Ghostty terminal runs Claude Code when its title starts with a Braille
    /// character (busy spinner) or `✳` (idle). Plain shells display something
    /// like `user@host:path` which fails this check.
    private static func isClaudeTerminal(_ t: GhosttyBridge.GhosttyTerminal) -> Bool {
        let trimmed = t.name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return false }
        if (0x2800...0x28FF).contains(first.value) { return true } // Braille
        if first.value == 0x2733 { return true }                   // ✳
        return false
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
