import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @State private var launchAtLogin: Bool = LaunchAgent.isEnabled
    @AppStorage("listMaxHeight") private var listMaxHeight: Double = 380

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
        .frame(width: 460, height: 360)
    }
}
