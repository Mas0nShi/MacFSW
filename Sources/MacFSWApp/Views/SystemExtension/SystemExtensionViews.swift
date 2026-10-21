import MacFSWCore
import SwiftUI

struct SystemExtensionSettingsPane: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("State", value: model.extensionStatus.installState.title)
                Text(model.extensionStatus.installMessage)
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
                        model.extensionStatus.openLoginItemsSettings()
                    } label: {
                        Label("Login Items & Extensions", systemImage: "gear")
                    }

                    Button {
                        model.extensionStatus.openFullDiskAccessSettings()
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
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.extensionStatus.installState.symbolName)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                Text(model.extensionStatus.installState.title)
                    .font(.callout.weight(.medium))
                Spacer()
                if model.extensionStatus.installState == .activating || model.extensionStatus.installState == .unknown {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(model.extensionStatus.installMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(5)

            switch model.extensionStatus.installState {
            case .ready:
                if model.session.captureHealth.fullDiskAccessHint {
                    fullDiskAccessActions
                } else {
                    EmptyView()
                }
            case .needsApproval:
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.extensionStatus.openLoginItemsSettings()
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
                if model.session.captureHealth.fullDiskAccessHint {
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
                    model.extensionStatus.openLoginItemsSettings()
                } label: {
                    Label("Login Items & Extensions", systemImage: "gear")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch model.extensionStatus.installState {
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
                model.extensionStatus.openFullDiskAccessSettings()
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
