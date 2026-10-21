import AppKit
import MacFSWAnalysis
import SwiftUI

struct AnalysisSettingsPane: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section("Provider") {
                Picker("Endpoint", selection: $preferences.llmSettings.endpoint) {
                    ForEach(MacFSWLLMEndpoint.allCases) { endpoint in
                        Text(endpoint.title).tag(endpoint)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Base URL", text: $preferences.llmSettings.baseURL)

                SecureField("API Key", text: $preferences.apiKey)

                TextField("Model", text: $preferences.llmSettings.model)

                Toggle("Stream response", isOn: $preferences.llmSettings.streamResponses)
                    .toggleStyle(.checkbox)
            }

            Section("Limits") {
                Stepper(value: $preferences.llmSettings.maxEvents, in: 1...20_000, step: 50) {
                    LabeledContent("Max Events", value: "\(model.preferences.llmSettings.maxEvents)")
                }

                Stepper(value: $preferences.llmSettings.tokenBudget, in: 256...200_000, step: 1_000) {
                    LabeledContent("Token Budget", value: "\(model.preferences.llmSettings.tokenBudget)")
                }

                Stepper(value: $preferences.llmSettings.timeoutSeconds, in: 5...600, step: 5) {
                    LabeledContent("Timeout", value: "\(model.preferences.llmSettings.timeoutSeconds)s")
                }
            }

            Section("Prompt") {
                Picker("Output Language", selection: $preferences.llmSettings.outputLanguage) {
                    ForEach(MacFSWAnalysisOutputLanguage.allCases) { language in
                        Text(language.pickerTitle).tag(language)
                    }
                }

                Stepper(value: $preferences.llmSettings.promptEventCharacterBudget, in: 10_000...1_000_000, step: 10_000) {
                    LabeledContent(
                        "Event Sample Budget",
                        value: "\(model.preferences.llmSettings.promptEventCharacterBudget.formatted()) chars ≈ \(MacFSWTokenEstimator.estimatedTokens(forCharacters: model.preferences.llmSettings.promptEventCharacterBudget).formatted()) tokens"
                    )
                }

                AnalysisTemplateList()
            }

            Section("Connection") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            model.testLLMConnection()
                        } label: {
                            Label("Test Connection", systemImage: "network")
                        }
                        .disabled(model.analysis.isTestingConnection)

                        if model.analysis.isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Spacer(minLength: 12)

                        MacFSWConnectionStatusBadge(state: model.analysis.connectionTestState)
                    }

                    if case .failed(let error) = model.analysis.connectionTestState {
                        MacFSWConnectionErrorCallout(error: error)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Analysis sends a process-scoped summary, operation counts, top paths, and event samples selected within the character budget. Pick or duplicate a prompt template above. API keys are stored in Keychain.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(18)
        .onChange(of: model.preferences.llmSettings) {
            // A finished connection test no longer describes edited settings.
            model.analysis.resetConnectionStateIfIdle()
        }
        .onChange(of: model.preferences.apiKey) {
            model.analysis.resetConnectionStateIfIdle()
        }
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
