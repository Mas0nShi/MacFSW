import AppKit
import MacFSWAnalysis
import MacFSWCore
import SwiftUI

enum MacFSWSettingsSection: String, CaseIterable, Identifiable {
    case general
    case analysis
    case capture
    case systemExtension
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            "General"
        case .analysis:
            "Analysis"
        case .capture:
            "Capture"
        case .systemExtension:
            "System Extension"
        case .logs:
            "Logs"
        }
    }

    var symbolName: String {
        switch self {
        case .general:
            "gearshape"
        case .analysis:
            "sparkles.rectangle.stack"
        case .capture:
            "record.circle"
        case .systemExtension:
            "puzzlepiece.extension"
        case .logs:
            "doc.text.magnifyingglass"
        }
    }

    var isBeta: Bool {
        switch self {
        case .analysis:
            true
        case .general, .capture, .systemExtension, .logs:
            false
        }
    }
}

struct SettingsView: View {
    @State private var selection: MacFSWSettingsSection = .analysis

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(MacFSWSettingsSection.allCases) { section in
                    HStack(spacing: 6) {
                        Label(section.title, systemImage: section.symbolName)
                        if section.isBeta {
                            MacFSWBetaBadge()
                        }
                    }
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            Group {
                switch selection {
                case .general:
                    GeneralSettingsPane()
                case .analysis:
                    AnalysisSettingsPane()
                case .capture:
                    CaptureSettingsPane()
                case .systemExtension:
                    SystemExtensionSettingsPane()
                case .logs:
                    LogsSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct GeneralSettingsPane: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        Form {
            Section("Startup") {
                Picker("Default Page", selection: $model.defaultStartupPage) {
                    ForEach(MacFSWNavigationPage.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
            }
            Section("Processes") {
                Toggle("Show exited processes by default", isOn: $model.defaultIncludeExitedProcesses)
                    .toggleStyle(.checkbox)
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }
}

struct LogsSettingsPane: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        Form {
            Section("Diagnostics") {
                Toggle("Write diagnostic logs", isOn: $model.diagnosticLoggingEnabled)
                    .toggleStyle(.checkbox)

                Picker("Minimum Level", selection: $model.diagnosticLogLevel) {
                    ForEach(MacFSWAppLogLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .disabled(!model.diagnosticLoggingEnabled)
            }

            Section("Location") {
                Text(model.diagnosticLogFilePath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                HStack {
                    Button {
                        model.openLogsFolder()
                    } label: {
                        Label("Open Logs Folder", systemImage: "folder")
                    }

                    Button {
                        model.copyLogFilePath()
                    } label: {
                        Label("Copy Path", systemImage: "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        model.clearDiagnosticLog()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                }
            }

            if let error = model.diagnosticLogWriteError {
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

struct AnalysisSettingsPane: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Endpoint", selection: Binding(
                    get: { model.llmSettings.endpoint },
                    set: { model.llmSettings.endpoint = $0 }
                )) {
                    ForEach(MacFSWLLMEndpoint.allCases) { endpoint in
                        Text(endpoint.title).tag(endpoint)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Base URL", text: Binding(
                    get: { model.llmSettings.baseURL },
                    set: { model.llmSettings.baseURL = $0 }
                ))

                SecureField("API Key", text: Binding(
                    get: { model.llmSettings.apiKey },
                    set: { model.llmSettings.apiKey = $0 }
                ))

                TextField("Model", text: Binding(
                    get: { model.llmSettings.model },
                    set: { model.llmSettings.model = $0 }
                ))

                Toggle("Stream response", isOn: Binding(
                    get: { model.llmSettings.streamResponses },
                    set: { model.llmSettings.streamResponses = $0 }
                ))
                .toggleStyle(.checkbox)
            }

            Section("Limits") {
                Stepper(value: Binding(
                    get: { model.llmSettings.maxEvents },
                    set: { model.llmSettings.maxEvents = $0 }
                ), in: 1...20_000, step: 50) {
                    LabeledContent("Max Events", value: "\(model.llmSettings.maxEvents)")
                }

                Stepper(value: Binding(
                    get: { model.llmSettings.tokenBudget },
                    set: { model.llmSettings.tokenBudget = $0 }
                ), in: 256...200_000, step: 1_000) {
                    LabeledContent("Token Budget", value: "\(model.llmSettings.tokenBudget)")
                }

                Stepper(value: Binding(
                    get: { model.llmSettings.timeoutSeconds },
                    set: { model.llmSettings.timeoutSeconds = $0 }
                ), in: 5...600, step: 5) {
                    LabeledContent("Timeout", value: "\(model.llmSettings.timeoutSeconds)s")
                }
            }

            Section("Connection") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            model.testLLMConnection()
                        } label: {
                            Label("Test Connection", systemImage: "network")
                        }
                        .disabled(model.isTestingLLMConnection)

                        if model.isTestingLLMConnection {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer(minLength: 12)

                        MacFSWConnectionStatusBadge(state: model.llmConnectionTestState)
                    }

                    if case .failed(let error) = model.llmConnectionTestState {
                        MacFSWConnectionErrorCallout(error: error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Analysis sends a process-scoped summary, operation counts, top paths, and recent event samples. API keys are stored in Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }
}


struct CaptureSettingsPane: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        Form {
            Group {
                Section("Capture Profile") {
                    Picker("Profile", selection: Binding(
                        get: { model.session.captureConfig.profile },
                        set: { model.updateCaptureProfile($0) }
                    )) {
                        ForEach(MacFSWCaptureProfile.allCases) { profile in
                            Text(profile.settingsTitle).tag(profile)
                        }
                    }

                    Stepper(value: Binding(
                        get: { model.session.captureConfig.maxCaptureDurationSeconds },
                        set: { model.updateCaptureDuration($0) }
                    ), in: 5...86_400, step: 60) {
                        LabeledContent("Duration", value: "\(model.session.captureConfig.maxCaptureDurationSeconds)s")
                    }
                }

                Section("Batching") {
                    Stepper(value: Binding(
                        get: { model.session.captureConfig.batchSize },
                        set: { model.updateCaptureBatchSize($0) }
                    ), in: 1...10_000, step: 64) {
                        LabeledContent("Batch Size", value: "\(model.session.captureConfig.batchSize)")
                    }

                    Stepper(value: Binding(
                        get: { model.session.captureConfig.batchIntervalMS },
                        set: { model.updateCaptureBatchInterval($0) }
                    ), in: 10...5_000, step: 10) {
                        LabeledContent("Batch Interval", value: "\(model.session.captureConfig.batchIntervalMS)ms")
                    }
                }

                Section("Excluded Processes") {
                    TextEditor(text: Binding(
                        get: { model.session.captureConfig.excludedProcessNames.joined(separator: "\n") },
                        set: { model.updateExcludedProcesses($0) }
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 72)
                }

                Section("Excluded Paths") {
                    TextEditor(text: Binding(
                        get: { model.session.captureConfig.excludePaths.joined(separator: "\n") },
                        set: { model.updateExcludePaths($0) }
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 72)
                }
            }
            .disabled(model.captureSettingsLocked)

            if model.captureSettingsLocked {
                Section("Locked") {
                    Text("Capture settings are locked while recording or connecting.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(18)
    }
}

struct MacFSWConnectionStatusBadge: View {
    let state: MacFSWConnectionTestState

    var body: some View {
        Label(state.badgeTitle, systemImage: state.badgeSymbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(state.badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(state.badgeColor.opacity(0.10), in: Capsule())
            .accessibilityLabel("Connection status: \(state.badgeTitle)")
    }
}

struct MacFSWConnectionErrorCallout: View {
    let error: MacFSWConnectionTestError
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(error.title)
                        .font(.callout.weight(.semibold))
                    Text(error.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            DisclosureGroup("Provider Response", isExpanded: $showsDetails) {
                Text(error.diagnostic)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            }
            .font(.caption)

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(error.diagnostic, forType: .string)
            } label: {
                Label("Copy Details", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        )
    }
}
