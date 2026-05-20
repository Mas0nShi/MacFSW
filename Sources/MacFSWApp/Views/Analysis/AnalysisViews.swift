import MarkdownView
import SwiftUI

struct AnalysisResultsView: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

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
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Analysis")
                        .font(.headline)
                    MacFSWBetaBadge()
                }
                Text(model.analysisStatusText)
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

            if model.isAnalysisRunning {
                Button {
                    model.cancelAnalysis()
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
                model.clearAnalysisHistory()
            } label: {
                Label("Clear History", systemImage: "trash")
            }
            .disabled(model.analysisResults.isEmpty)
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
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        SidebarSectionHeader("Reports")
                        Spacer()
                        Text("\(model.analysisResults.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text("Completed analysis runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if model.analysisResults.isEmpty {
                    Text("No reports")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.analysisResults) { result in
                                Button {
                                    model.selectAnalysis(result)
                                } label: {
                                    AnalysisHistoryRow(
                                        result: result,
                                        isSelected: model.selectedAnalysisID == result.id
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
            Text("\(result.payloadEventCount)/\(result.eventCount) events · \(result.operationCount) ops")
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
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        Group {
            if model.isAnalysisRunning || !model.streamingAnalysisMarkdown.isEmpty {
                AnalysisMarkdownReportView(
                    title: model.selectedAnalysisProcess?.displayName ?? "Running Analysis",
                    subtitle: "Streaming response",
                    eventCount: nil,
                    pathCount: nil,
                    operationCount: nil,
                    markdown: model.streamingAnalysisMarkdown,
                    isStreaming: model.isAnalysisRunning,
                    error: model.analysisRunError
                )
            } else if let error = model.analysisRunError {
                AnalysisErrorPane(error: error)
            } else if let result = model.selectedAnalysis {
                AnalysisMarkdownReportView(
                    title: result.processDisplayName,
                    subtitle: "\(result.scope) · \(result.providerSummary) · \(String(format: "%.1fs", result.durationSeconds))",
                    eventCount: result.eventCount,
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
    let eventCount: Int?
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

                    if let eventCount, let pathCount, let operationCount {
                        HStack(spacing: 10) {
                            AnalysisStat(title: "Events", value: "\(eventCount)")
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
