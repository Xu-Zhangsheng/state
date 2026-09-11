import AppKit
import Defaults
import SwiftUI

struct GeneralSettingsView: View {
    @State private var appLanguage = AppLanguage.selected
    @Default(.launchAtLogin) var launchAtLogin
    @Default(.disableNotifications) var disableNotifications

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: "1.0 Beta")
            }

            Section("Language") {
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.displayName).tag(language)
                    }
                }
                .onChange(of: appLanguage) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    AppLanguageController.apply(newValue)
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section {
                Toggle("Disable all notifications", isOn: $disableNotifications)
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications")
                    Text("Control when state sends you notifications.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
        .onChange(of: launchAtLogin) { _, newValue in
            LaunchAtLoginService.shared.setLaunchAtLogin(newValue)
        }
    }
}

#Preview {
    GeneralSettingsView()
}
