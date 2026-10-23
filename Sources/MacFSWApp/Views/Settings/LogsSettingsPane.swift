import SwiftUI

struct LogsSettingsPane: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        @Bindable var log = model.log
        Form {
            Section("Diagnostics") {
                Toggle("Write diagnostic logs", isOn: $log.isEnabled)
                    .toggleStyle(.checkbox)

                Picker("Minimum Level", selection: $log.minimumLevel) {
                    ForEach(MacFSWAppLogLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .disabled(!model.log.isEnabled)
            }

            Section("Location") {
                Text(model.log.logFileURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                HStack {
                    Button {
                        model.log.openLogsFolder()
                    } label: {
                        Label("Open Logs Folder", systemImage: "folder")
                    }

                    Button {
                        model.log.copyLogFilePath()
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        model.log.clearLog()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                }
            }

            if let error = model.log.lastWriteError {
                Section("Write Error") {
                    Text(error)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }
}
