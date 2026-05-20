import MacFSWCore
import SwiftUI

struct SystemExtensionSettingsPane: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("State", value: model.extensionInstallState.title)
                Text(model.extensionInstallMessage)
                    .foregroundStyle(.secondary)
            }

            Section("Actions") {
                HStack {
                    Button {
                        model.activateSystemExtension()
                    } label: {
                        Label("Enable or Update", systemImage: "puzzlepiece.extension")
                    }

                    Button {
                        model.checkSystemExtensionAgain()
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }

                    Button {
                        model.openSystemExtensionSettings()
                    } label: {
                        Label("Login Items & Extensions", systemImage: "gear")
                    }

                    Button {
                        model.openFullDiskAccessSettings()
                    } label: {
                        Label("Open Full Disk Access", systemImage: "lock.shield")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }
}

extension MacFSWCaptureProfile {
    var settingsTitle: String {
        switch self {
        case .focusedMutations:
            "Focused Mutations"
        case .verboseReads:
            "Verbose Reads"
        case .fullSystemBurst:
            "Full System Burst"
        }
    }
}

struct SystemExtensionStatusView: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.extensionInstallState.symbolName)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                Text(model.extensionInstallState.title)
                    .font(.callout.weight(.medium))
                Spacer()
                if model.extensionInstallState == .activating || model.extensionInstallState == .unknown {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(model.extensionInstallMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(5)

            switch model.extensionInstallState {
            case .ready:
                if model.captureHealth.fullDiskAccessHint {
                    fullDiskAccessActions
                } else {
                    EmptyView()
                }
            case .needsApproval:
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.openSystemExtensionSettings()
                    } label: {
                        Label("Login Items & Extensions", systemImage: "gear")
                    }

                    Button {
                        model.checkSystemExtensionAgain()
                    } label: {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
            case .notReady, .failed, .unknown:
                if model.captureHealth.fullDiskAccessHint {
                    fullDiskAccessActions
                } else {
                    Button {
                        model.activateSystemExtension()
                    } label: {
                        Label("Enable System Extension", systemImage: "puzzlepiece.extension")
                    }
                    .buttonStyle(.borderless)
                }
            case .activating:
                Button {
                    model.openSystemExtensionSettings()
                } label: {
                    Label("Login Items & Extensions", systemImage: "gear")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch model.extensionInstallState {
        case .ready:
            .green
        case .failed:
            .red
        case .needsApproval:
            .orange
        case .activating:
            .blue
        case .unknown, .notReady:
            .secondary
        }
    }

    private var fullDiskAccessActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.openFullDiskAccessSettings()
            } label: {
                Label("Open Full Disk Access", systemImage: "lock.shield")
            }

            Button {
                model.checkSystemExtensionAgain()
            } label: {
                Label("Check Again", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
    }
}
