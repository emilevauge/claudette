import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @State private var launchAtLogin: Bool = LaunchAgent.isEnabled
    @AppStorage("listMaxHeight") private var listMaxHeight: Double = 380

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
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.compress.vertical")
                        .foregroundStyle(.secondary)
                    Slider(value: $listMaxHeight, in: 240...1400, step: 20)
                    Image(systemName: "rectangle.expand.vertical")
                        .foregroundStyle(.secondary)
                    Text("\(Int(listMaxHeight)) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
            } header: {
                Text(L("List height"))
            } footer: {
                Text(L("Maximum height of the session list in the menu bar popover."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            aboutSection

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
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
    }

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
