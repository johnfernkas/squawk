import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Section("Global Shortcut") {
                HStack {
                    Text("Open Squawk")
                    Spacer()
                    Text("⌘⇧M")
                        .foregroundStyle(.secondary)
                        .fontWeight(.medium)
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                        .padding(.top, 1)
                    Text("Requires Input Monitoring permission to work while another app is focused.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button("Open Privacy Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                }
                .font(.system(size: 12))
            }
        }
        .formStyle(.grouped)
        .frame(width: 280)
        .fixedSize()
    }
}
