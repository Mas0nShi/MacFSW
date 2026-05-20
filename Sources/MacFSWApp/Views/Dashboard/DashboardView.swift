import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 280)

            Divider()

            ZStack {
                if model.selectedPage == .monitor {
                    MonitorView()
                        .transition(.opacity)
                } else {
                    AnalysisResultsView()
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.selectedPage == .monitor, model.shouldShowInspector {
                Divider()
                    .transition(.opacity)

                InspectorView(event: model.selectedEvent, isLoading: model.selectedEventIsLoading)
                    .frame(width: 380)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: model.selectedPage)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                RecordingIndicatorView(isRecording: bottomCaptureIsRecording)
                Text(bottomCaptureTitle)
                    .fontWeight(.medium)
            }
            .frame(width: 96, alignment: .leading)

            Divider()
                .frame(height: 14)

            Text("\(model.captureStats.deliveredEvents) captured")
                .monospacedDigit()
            Text("\(model.visibleEventCount) shown")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if model.captureStats.droppedEvents > 0 {
                Text("\(model.captureStats.droppedEvents) dropped")
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
            if model.captureState == .recording {
                Label(tableRefreshTitle, systemImage: tableRefreshSymbol)
                    .foregroundStyle(tableRefreshColor)
                    .frame(width: 68, alignment: .leading)
            }
            if model.captureState == .recording, model.followMode == .live, !model.isViewingLiveEdge {
                Label("Viewing history", systemImage: "arrow.up")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if let lastUpdatedAt = model.lastUpdatedAt {
                Text("Updated \(lastUpdatedAt.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 124, alignment: .trailing)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    private var bottomCaptureIsRecording: Bool {
        switch model.captureState {
        case .connecting, .recording, .stopping:
            true
        case .idle, .stopped, .degraded, .failed:
            false
        }
    }

    private var bottomCaptureTitle: String {
        bottomCaptureIsRecording ? "Recording" : "Idle"
    }

    private var tableRefreshTitle: String {
        model.followMode == .live ? "Live" : "Paused"
    }

    private var tableRefreshSymbol: String {
        model.followMode == .live ? "dot.radiowaves.left.and.right" : "pause.circle"
    }

    private var tableRefreshColor: Color {
        model.followMode == .live ? .green : .orange
    }
}

