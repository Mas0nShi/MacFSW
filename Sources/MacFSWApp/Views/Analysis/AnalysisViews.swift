import MarkdownView
import SwiftUI

struct AnalysisResultsView: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            AnalysisHistorySidebar()
                .frame(width: 260)
                .background(.bar)

            Divider()

            VStack(spacing: 0) {
                AnalysisHeaderView()
                AnalysisReportPane()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AnalysisHeaderView: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Analysis")
                        .font(.headline)
                    MacFSWBetaBadge()
                }
                Text(model.analysis.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 20)

            if let process = model.selectedAnalysisProcess {
                HStack(spacing: 6) {
                    ProcessIconView(summary: process)
                    Text(process.displayName)
                        .lineLimit(1)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            }

            Picker("Template", selection: Binding(
                get: { model.analysisTemplates.selectedTemplateID },
                set: { model.analysisTemplates.selectedTemplateID = $0 }
            )) {
                Section("Built-in") {
                    ForEach(model.analysisTemplates.allTemplates.filter(\.isBuiltIn)) { template in
                        Text(template.name).tag(template.id)
                    }
                }
                let custom = model.analysisTemplates.allTemplates.filter { !$0.isBuiltIn }
                if !custom.isEmpty {
                    Section("Custom") {
                        ForEach(custom) { template in
                            Text(template.name).tag(template.id)
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
            .disabled(model.analysis.isRunning)

            if model.analysis.isRunning {
                Button {
                    model.analysis.cancelAnalysis()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    model.runAnalysis()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(!model.canRunAnalysis)
            }

            Button {
                model.analysis.clearHistory()
            } label: {
                Label("Clear History", systemImage: "trash")
            }
            .disabled(model.analysis.results.isEmpty)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16)
        .frame(height: MacFSWUILayout.pageHeaderHeight)
        .background(.background)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct AnalysisHistorySidebar: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        SidebarSectionHeader("Reports")
                        Spacer()
                        Text("\(model.analysis.results.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text("Completed analysis runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if model.analysis.results.isEmpty {
                    Text("No reports")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.analysis.results) { result in
                                Button {
                                    model.selectAnalysis(result)
                                } label: {
                                    AnalysisHistoryRow(
                                        result: result,
                                        isSelected: model.analysis.selectedResultID == result.id
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .overlay(alignment: .trailing) {
            Divider()
        }
    }
}

struct AnalysisHistoryRow: View {
    let result: MacFSWAnalysisResult
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.processDisplayName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text(result.createdAt.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(result.sampledEventCount)/\(result.totalEventCount) events · \(result.operationCount) ops")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
    }
}

struct AnalysisReportPane: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        Group {
            if model.analysis.isRunning || !model.analysis.streamingMarkdown.isEmpty {
                AnalysisMarkdownReportView(
                    title: model.selectedAnalysisProcess?.displayName ?? "Running Analysis",
                    subtitle: "Streaming response",
                    eventsLabel: nil,
                    pathCount: nil,
                    operationCount: nil,
                    markdown: model.analysis.streamingMarkdown,
                    isStreaming: model.analysis.isRunning,
                    error: model.analysis.runError
                )
            } else if let error = model.analysis.runError {
                AnalysisErrorPane(error: error)
            } else if let result = model.analysis.selectedAnalysis {
                AnalysisMarkdownReportView(
                    title: result.processDisplayName,
                    subtitle: "\(result.scope) · \(result.providerSummary) · \(result.templateName) · \(String(format: "%.1fs", result.durationSeconds))",
                    eventsLabel: "\(result.sampledEventCount)/\(result.totalEventCount)",
                    pathCount: result.pathCount,
                    operationCount: result.operationCount,
                    markdown: result.markdown,
                    isStreaming: false,
                    error: nil
                )
            } else if let process = model.selectedAnalysisProcess {
                ContentUnavailableView(
                    "Ready to Analyze",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Run analysis for \(process.displayName).")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Report Selected",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Choose a process and run analysis, or select a completed report.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AnalysisMarkdownReportView: View {
    let title: String
    let subtitle: String
    /// Rendered as "sampled/total" so the card is honest about how much of
    /// the session the model actually saw.
    let eventsLabel: String?
    let pathCount: Int?
    let operationCount: Int?
    let markdown: String
    let isStreaming: Bool
    let error: MacFSWConnectionTestError?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.title2.weight(.semibold))
                                .lineLimit(1)
                            if isStreaming {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let eventsLabel, let pathCount, let operationCount {
                        HStack(spacing: 10) {
                            AnalysisStat(title: "Events", value: eventsLabel)
                            AnalysisStat(title: "Paths", value: "\(pathCount)")
                            AnalysisStat(title: "Operations", value: "\(operationCount)")
                        }
                    }

                    if let error {
                        MacFSWConnectionErrorCallout(error: error)
                    }

                    if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(isStreaming ? "Waiting for model output..." : "No markdown output.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                    } else {
                        MarkdownView(markdown)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("analysis-report-bottom")
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .onChange(of: markdown.count) {
                guard isStreaming else {
                    return
                }
                proxy.scrollTo("analysis-report-bottom", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct AnalysisErrorPane: View {
    let error: MacFSWConnectionTestError

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Analysis Failed")
                    .font(.title2.weight(.semibold))
                Text("The model request did not complete.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            MacFSWConnectionErrorCallout(error: error)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct AnalysisStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(width: 130, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
