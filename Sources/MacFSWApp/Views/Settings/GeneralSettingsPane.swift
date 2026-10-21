import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section("Startup") {
                Picker("Default Page", selection: $preferences.defaultStartupPage) {
                    ForEach(MacFSWNavigationPage.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
            }
            Section("Processes") {
                Toggle("Show exited processes by default", isOn: $preferences.defaultIncludeExitedProcesses)
                    .toggleStyle(.checkbox)
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }
}
