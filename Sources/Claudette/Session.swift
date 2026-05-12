import Foundation

/// Une session Claude Code détectée localement.
struct ClaudeSession: Identifiable, Hashable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let startedAt: Date
    let updatedAt: Date
    let version: String
    let status: String       // "busy" ou "idle" tel que rapporté par Claude Code
    let kind: String
    let entrypoint: String
    let name: String?

    /// Renseigné par le SessionStore si on a trouvé le terminal Ghostty correspondant.
    /// C'est notre source de vérité pour `isBusy` car le titre est rafraichi par Claude
    /// à chaque tick du spinner.
    var terminalTitle: String?
    var terminalId: String?

    var id: String { sessionId.isEmpty ? "\(pid)" : sessionId }

    /// Libellé affiché : nom explicite si présent, sinon le basename du cwd.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Chaîne utilisée pour retrouver la fenêtre Ghostty correspondante.
    var windowSearchKey: String {
        if let name, !name.isEmpty { return name }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Statut effectif : priorité au titre du terminal Ghostty (mis à jour à chaque
    /// tick du spinner par Claude), sinon fallback sur le `status` du JSON.
    var isBusy: Bool {
        if let title = terminalTitle?.trimmingCharacters(in: .whitespaces),
           let first = title.unicodeScalars.first {
            // Plage Braille U+2800..U+28FF : Claude affiche un spinner Braille quand busy.
            if (0x2800...0x28FF).contains(first.value) { return true }
            // ✳ (U+2733) : Claude attend une saisie utilisateur.
            if first.value == 0x2733 { return false }
        }
        return status == "busy"
    }
}
