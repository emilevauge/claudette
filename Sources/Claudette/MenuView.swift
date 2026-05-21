import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var store: SessionStore

    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    @State private var showingSettings: Bool = false
    @FocusState private var searchFocused: Bool

    /// List max height. Hardcoded to a tall ceiling; the popover itself
    /// is otherwise compact and the system never lets it exceed the
    /// screen height.
    private let listMaxHeight: CGFloat = 1400

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
                s.aiTitle ?? "",
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
                .frame(maxHeight: listMaxHeight)
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
                showingSettings.toggle()
            }
            .keyboardShortcut(",")
            // `arrowEdge: .trailing` anchors the popover's arrow to the
            // gear button's trailing edge, putting the settings panel to
            // the right of the button.
            .popover(isPresented: $showingSettings, arrowEdge: .trailing) {
                SettingsView()
            }

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

    // MARK: actions

    private func focusSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        focus(filtered[selectedIndex])
    }

    private func focus(_ session: ClaudeSession) {
        // Close the popover first: NSPopover.transient closes on its own as
        // soon as the target app takes focus, and closing it manually
        // afterwards can interrupt the AppleScript activation chain.
        AppDelegate.shared.closePopover()
        if session.isClaudeDesktop {
            _ = ClaudeDesktopBridge.focus(session: session)
        } else {
            _ = GhosttyBridge.focus(session: session)
        }
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

                    if let aiTitle = session.aiTitle, !aiTitle.isEmpty {
                        Text(aiTitle)
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(aiTitle)
                    }

                    boldedPath(session.cwd)
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

                    if let fraction = session.contextFraction {
                        contextBar(fraction: fraction)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    remoteControlButton
                    appAffordance
                }
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
        let color = Self.color(for: session.phase)

        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 16, height: 16)

            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
                // Pulse only when something is actually happening (busy or
                // needs,attention). Idle sessions get a static dot, otherwise
                // every row blinks for no reason and pulls the eye.
                .symbolEffect(.pulse, options: .repeating, isActive: session.phase != .idle)
        }
    }

    private static let orange = Color(red: 1.00, green: 0.58, blue: 0.00)
    private static let red    = Color(red: 0.92, green: 0.26, blue: 0.21)
    private static let green  = Color(red: 0.20, green: 0.78, blue: 0.35)

    private static func color(for phase: ClaudeSession.Phase) -> Color {
        switch phase {
        case .busy:           return orange
        case .needsAttention: return red
        case .idle:           return green
        }
    }

    /// Small antenna icon that types `/remote-control` into the session's
    /// Ghostty terminal so the user can scan the resulting QR code with
    /// the Claude mobile app. Faded and unclickable for Claude Desktop
    /// background agents, which have no terminal of their own. When
    /// remote control is already active for the session (inferred from
    /// `bridgeSessionId` in the session JSON), the icon takes the accent
    /// color and the tooltip reflects the live state.
    @ViewBuilder
    private var remoteControlButton: some View {
        let active = session.isRemoteControlActive
        Button {
            RemoteControlActivator.enable(session: session)
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor)
                                        : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
        }
        .buttonStyle(.plain)
        .disabled(session.isClaudeDesktop)
        .opacity(session.isClaudeDesktop ? 0.3 : 1.0)
        .help(active ? L("Remote control active") : L("Enable remote control"))
    }

    /// Right,side affordance: the real .app icon of the target (Ghostty
    /// terminal or Claude Desktop), rendered in black,and,white via
    /// `saturation(0)` to blend with the row's neutral palette.
    @ViewBuilder
    private var appAffordance: some View {
        let bundleId = session.isClaudeDesktop
            ? "com.anthropic.claudefordesktop"
            : "com.mitchellh.ghostty"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .saturation(0)
                .opacity(0.55)
        } else {
            // App not installed: fall back to the previous SF Symbol so the
            // row still has something on the right.
            Image(systemName: session.isClaudeDesktop
                  ? "app.dashed"
                  : "arrow.up.right.square")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        HStack(spacing: 4) {
            switch session.phase {
            case .busy:
                Text(L("thinking…"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.00))
            case .needsAttention:
                Text(L("needs attention"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(red: 0.80, green: 0.20, blue: 0.18))
            case .idle:
                EmptyView()
            }
            subagentCounter
        }
    }

    /// Tiny inline counter showing how many subagents are actively writing
    /// to their transcript. `↳ N` next to the status label, tertiary color
    /// so it doesn't compete with the main status text. Hover tooltip
    /// surfaces `agentType: description` for each.
    @ViewBuilder
    private var subagentCounter: some View {
        if !session.activeSubagents.isEmpty {
            Text("· ▶ \(session.activeSubagents.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(subagentTooltip)
        }
    }

    private var subagentTooltip: String {
        let lines: [String] = session.activeSubagents.map {
            $0.description.isEmpty ? $0.agentType : "\($0.agentType): \($0.description)"
        }
        let header = session.activeSubagents.count == 1
            ? L("1 active subagent")
            : L("\(session.activeSubagents.count) active subagents")
        return ([header] + lines.map { "• " + $0 }).joined(separator: "\n")
    }

    /// Thin context,fill bar shown at the bottom of each row. Color
    /// shifts green → yellow → orange → red as the model's context window
    /// fills up. Tooltip surfaces the exact percentage.
    ///
    /// The empty rail is always rendered (even at 0%) so a freshly,started
    /// session still shows a visible bar; the colored fill collapses to
    /// zero width when `fraction == 0` instead of clamping to 2pt, otherwise
    /// 0% would look identical to 1%.
    @ViewBuilder
    private func contextBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.35))
                if fraction > 0 {
                    Capsule()
                        .fill(Self.contextColor(for: fraction))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 3.5)
        .padding(.top, 1)
        .help(String(format: "context: %.0f%%", fraction * 100))
    }

    private static func contextColor(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.50: return Color(red: 0.20, green: 0.78, blue: 0.35)  // green
        case ..<0.75: return Color(red: 0.95, green: 0.75, blue: 0.10)  // yellow
        case ..<0.90: return Color(red: 1.00, green: 0.58, blue: 0.00)  // orange
        default:      return Color(red: 0.92, green: 0.26, blue: 0.21)  // red
        }
    }

    private func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Same as `prettyPath`, but returns a `Text` whose last path
    /// component (the current directory's basename) is bold. So
    /// `~/go/src/github.com/traefik/ingress-nginx-migration` reads as
    /// `~/go/src/github.com/traefik/` + **`ingress-nginx-migration`**.
    /// Lets the row's path catch the eye at a glance without growing
    /// vertically, even when truncated from the head.
    private func boldedPath(_ rawPath: String) -> Text {
        let pretty = prettyPath(rawPath)
        guard let lastSlash = pretty.lastIndex(of: "/") else {
            return Text(pretty).bold()
        }
        let after = pretty.index(after: lastSlash)
        let parent = String(pretty[..<after])
        let basename = String(pretty[after...])
        return Text(parent) + Text(basename).bold()
    }

    /// Elapsed time since the session started: "2d 3h", "1h 23m", "12m".
    private func sessionDuration(_ start: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(start))
        return Self.durationFormatter.string(from: interval) ?? ""
    }

    /// Cached as a static (instantiating one is costly; this avoids creating
    /// a new formatter on every body re-render while scrolling).
    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f
    }()
}
