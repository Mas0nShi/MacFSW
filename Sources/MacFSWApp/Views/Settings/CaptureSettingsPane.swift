import MacFSWCore
import SwiftUI

struct CaptureSettingsPane: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    private func config<Value>(_ keyPath: WritableKeyPath<MacFSWCaptureConfig, Value>) -> Binding<Value> {
        Binding(
            get: { model.session.research.captureConfig[keyPath: keyPath] },
            set: { value in model.updateCaptureConfig { $0[keyPath: keyPath] = value } }
        )
    }

    /// One entry per line; blank lines and surrounding whitespace dropped.
    private func lines(_ keyPath: WritableKeyPath<MacFSWCaptureConfig, [String]>) -> Binding<String> {
        Binding(
            get: { model.session.research.captureConfig[keyPath: keyPath].joined(separator: "\n") },
            set: { text in
                model.updateCaptureConfig {
                    $0[keyPath: keyPath] = text
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
            }
        )
    }

    var body: some View {
        Form {
            Group {
                Section("Capture Profile") {
                    Picker("Profile", selection: Binding(
                        get: { model.session.research.captureConfig.profile },
                        set: { profile in
                            model.updateCaptureConfig { config in
                                config.profile = profile
                                config.eventTypes = MacFSWCaptureConfig.defaultEventTypes(for: profile)
                            }
                        }
                    )) {
                        ForEach(MacFSWCaptureProfile.allCases) { profile in
                            Text(profile.settingsTitle).tag(profile)
                        }
                    }

                    Stepper(value: config(\.maxCaptureDurationSeconds), in: 5...86_400, step: 60) {
                        LabeledContent("Duration", value: "\(model.session.research.captureConfig.maxCaptureDurationSeconds)s")
                    }
                }

                Section("Batching") {
                    Stepper(value: config(\.batchSize), in: 1...10_000, step: 64) {
                        LabeledContent("Batch Size", value: "\(model.session.research.captureConfig.batchSize)")
                    }

                    Stepper(value: config(\.batchIntervalMS), in: 10...5_000, step: 10) {
                        LabeledContent("Batch Interval", value: "\(model.session.research.captureConfig.batchIntervalMS)ms")
                    }
                }

                Section("Excluded Processes") {
                    TextEditor(text: lines(\.excludedProcessNames))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 72)
                }

                Section("Excluded Paths") {
                    TextEditor(text: lines(\.excludePaths))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 72)
                }
            }
            .disabled(model.session.isCaptureActive)

            if model.session.isCaptureActive {
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
