import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var store: SessionStore

    @Environment(\.openSettings) private var openSettingsEnv

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var searchFocused: Bool

    /// Hauteur max de la liste, persistée entre lancements (configurée dans Réglages).
    @AppStorage("listMaxHeight") private var listMaxHeight: Double = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            content

            Divider()

            footer
        }
        .frame(width: 380)
        .onAppear {
            searchText = ""
            selectedIndex = 0
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: filtered.count) {
            selectedIndex = min(selectedIndex, max(filtered.count - 1, 0))
        }
    }

    // MARK: filtre

    private var filtered: [ClaudeSession] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.sessions }

        let tokens = q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return store.sessions.filter { s in
            let haystack = [
                s.name ?? "",
                s.cwd,
                URL(fileURLWithPath: s.cwd).lastPathComponent,
                s.displayName,
                "\(s.pid)"
            ].joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(L("Search (name, path)"), text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { focusSelected() }
                .onKeyPress(.escape) {
                    if searchText.isEmpty {
                        AppDelegate.shared.closePopover()
                    } else {
                        searchText = ""
                    }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    if !filtered.isEmpty {
                        selectedIndex = min(selectedIndex + 1, filtered.count - 1)
                    }
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selectedIndex = max(selectedIndex - 1, 0)
                    return .handled
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Text(L("\(filtered.count) active"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: contenu

    @ViewBuilder
    private var content: some View {
        if store.sessions.isEmpty {
            emptyState(L("No active Claude session"))
        } else if filtered.isEmpty {
            emptyState(L("No results for \"\(searchText)\""))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, session in
                            SessionRow(
                                session: session,
                                selected: index == selectedIndex,
                                onClick: { focus(session) }
                            )
                            .id(session.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: CGFloat(listMaxHeight))
                .onChange(of: selectedIndex) { _, newIndex in
                    guard filtered.indices.contains(newIndex) else { return }
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(filtered[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 2) {
            iconButton("arrow.clockwise", tooltip: L("Refresh")) {
                store.refresh()
            }
            .keyboardShortcut("r")

            iconButton("gearshape", tooltip: L("Settings…")) {
                openSettings()
            }
            .keyboardShortcut(",")

            Spacer()

            iconButton("power", tooltip: L("Quit")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func iconButton(
        _ systemName: String,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    private func openSettings() {
        AppDelegate.shared.closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openSettingsEnv()
    }

    // MARK: actions

    private func focusSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        focus(filtered[selectedIndex])
    }

    private func focus(_ session: ClaudeSession) {
        // Fermer le popover en premier : NSPopover.transient se ferme tout seul
        // dès que Ghostty prend le focus, et si on le ferme manuellement après,
        // ça peut interrompre la chaîne d'activation côté AppleScript.
        AppDelegate.shared.closePopover()
        _ = GhosttyBridge.focus(session: session)
    }
}

private struct SessionRow: View {
    let session: ClaudeSession
    let selected: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 8) {
                statusIndicator
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.displayName)
                            .font(.system(.body, design: .default).weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        statusLabel
                    }

                    Text(prettyPath(session.cwd))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)

                    HStack(spacing: 10) {
                        HStack(spacing: 3) {
                            Image(systemName: "hourglass")
                            Text(sessionDuration(session.startedAt))
                        }
                        .help(L("Total session duration"))

                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                            Text(sessionDuration(session.updatedAt))
                        }
                        .help(L("Since last activity"))
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        let color: Color = session.isBusy ? Self.orange : Self.green

        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 16, height: 16)

            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
                // SymbolEffect natif macOS 14 : Core Animation, pas de
                // re-render SwiftUI à chaque frame contrairement à un
                // ViewModifier scaleEffect+opacity custom.
                .symbolEffect(.pulse, options: .repeating, isActive: session.isBusy)
        }
    }

    private static let orange = Color(red: 1.00, green: 0.58, blue: 0.00)
    private static let green = Color(red: 0.20, green: 0.78, blue: 0.35)

    @ViewBuilder
    private var statusLabel: some View {
        if session.isBusy {
            Text(L("thinking…"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.00))
        } else if session.status == "idle" {
            Text(L("waiting"))
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color(red: 0.15, green: 0.60, blue: 0.25))
        }
    }

    private func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Durée écoulée depuis le démarrage de la session : "2 j 3 h", "1 h 23 min", "12 min".
    private func sessionDuration(_ start: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(start))
        return Self.durationFormatter.string(from: interval) ?? ""
    }

    /// Formatter caché en statique (sa création est coûteuse, on évite de
    /// l'instancier à chaque body re-render pendant le scroll).
    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()
}
