import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @State private var launchAtLogin: Bool = LaunchAgent.isEnabled

    /// Update,check state for the "About" section.
    @State private var updateChecking: Bool = false
    @State private var updateResult: UpdateChecker.ManualResult?

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder(
                    L("Show Claudette"),
                    name: .toggleClaudette
                )
            } header: {
                Text(L("Global shortcut"))
            } footer: {
                Text(L("Press the shortcut from any app to open or close Claudette."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(L("Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try LaunchAgent.enable()
                            } else {
                                try LaunchAgent.disable()
                            }
                        } catch {
                            // On failure, revert to the actual on-disk state.
                            launchAtLogin = LaunchAgent.isEnabled
                        }
                    }
            } header: {
                Text(L("Startup"))
            } footer: {
                Text(L("Automatically start Claudette when you log in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Always last: identity, version & legal info live at the bottom.
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let repoURL = URL(string: "https://github.com/emilevauge/claudette")!

    // MARK: about

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            HStack {
                Text(L("Version"))
                Spacer()
                Text(UpdateChecker.currentVersionString())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button(L("Check for updates")) {
                    Task { await runUpdateCheck() }
                }
                .disabled(updateChecking)

                if updateChecking {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                if let updateResult, !updateChecking {
                    updateResultLabel(updateResult)
                }
            }

            // Inline action when a newer version is available.
            if case let .newer(version, pageURL, dmgURL) = updateResult {
                HStack(spacing: 8) {
                    if let dmgURL {
                        Button(L("Update to \(version) now")) {
                            Task { await SelfUpdater.run(dmgURL: dmgURL) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(L("Release notes")) {
                        NSWorkspace.shared.open(pageURL)
                    }
                }
            }

            // Legal & source. Repo link uses Link so it gets the standard
            // hover/visited treatment and respects the user's default browser.
            HStack {
                Text(L("License"))
                Spacer()
                Text("MIT")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(L("Source"))
                Spacer()
                Link("github.com/emilevauge/claudette", destination: Self.repoURL)
                    .font(.callout)
            }

            Text(L("© 2026 Emile Vauge. Released under the MIT License."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text(L("About"))
        }
    }

    @ViewBuilder
    private func updateResultLabel(_ r: UpdateChecker.ManualResult) -> some View {
        switch r {
        case .upToDate:
            Label(L("Up to date"), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .newer(let v, _, _):
            Label(L("\(v) is available"), systemImage: "arrow.up.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func runUpdateCheck() async {
        updateChecking = true
        updateResult = nil
        updateResult = await UpdateChecker.checkManually()
        updateChecking = false
    }
}
