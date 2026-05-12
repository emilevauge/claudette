import Foundation
import Combine
import Darwin
import AppKit

/// Surveille `~/.claude/sessions/*.json` et publie les sessions dont le PID est vivant.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []

    /// Appelé chaque fois qu'une session passe de busy à non-busy.
    var onSessionBecameIdle: ((ClaudeSession) -> Void)?

    private var timer: Timer?
    private let sessionsDir: String
    private let pollInterval: TimeInterval

    /// Sessions qui étaient busy au refresh précédent (par id).
    private var previousBusy: Set<String> = []
    /// Premier refresh : on n'émet pas de transitions à froid.
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
            guard let session = Self.parse(path: path), Self.isAlive(pid: session.pid) else {
                continue
            }
            alive.append(session)
        }

        // Annoter avec le terminal Ghostty correspondant : son titre reflète
        // l'état réel de Claude (spinner Braille / ✳) en temps réel.
        let terminals = ghosttyIsRunning() ? GhosttyBridge.listTerminals() : []
        if !terminals.isEmpty {
            alive = alive.map { Self.annotate($0, with: terminals) }
        }

        // Tri : busy d'abord, puis les plus récents.
        alive.sort { a, b in
            if a.isBusy != b.isBusy { return a.isBusy }
            return a.updatedAt > b.updatedAt
        }

        // Détection des transitions busy → non busy.
        let currentBusy = Set(alive.filter { $0.isBusy }.map { $0.id })
        if hasBootstrapped {
            for s in alive where !s.isBusy && previousBusy.contains(s.id) {
                onSessionBecameIdle?(s)
            }
        }
        previousBusy = currentBusy
        hasBootstrapped = true

        sessions = alive
    }

    private func ghosttyIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" })
    }

    /// Cherche le terminal Ghostty correspondant à la session.
    /// 1) match par cwd normalisé
    /// 2) si plusieurs candidats, préférer ceux dont le titre commence par
    ///    un spinner Braille (busy) ou `✳` (idle) : c'est un terminal Claude,
    ///    pas un shell ordinaire ouvert dans le même dossier.
    /// 3) parmi les candidats restants, préférer celui dont le titre contient
    ///    le `name` de la session.
    /// 4) si aucun match cwd, fallback : titre contenant le name.
    private static func annotate(
        _ session: ClaudeSession,
        with terminals: [GhosttyBridge.GhosttyTerminal]
    ) -> ClaudeSession {
        let needle = (session.name?.isEmpty == false) ? session.name! : session.windowSearchKey
        let sessionCwd = normalize(session.cwd)

        let byCwd = terminals.filter { normalize($0.cwd) == sessionCwd }
        // Étape 2 : filtre Claude-only quand on a le choix.
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

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Un terminal Ghostty exécute Claude Code si son titre commence par un
    /// caractère Braille (spinner busy) ou `✳` (idle). Les shells ordinaires
    /// affichent typiquement `user@host:path` qui ne matche pas.
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
            name: raw["name"] as? String
        )
    }

    /// `kill(pid, 0)` ne tue rien : il vérifie juste que le process existe et est accessible.
    private static func isAlive(pid: Int32) -> Bool {
        return kill(pid, 0) == 0
    }
}
