import AppKit
import MacFSWCore
import SwiftUI

struct DashboardView: View {
    @Environment(MacFSWAppCoordinator.self) private var model
    @AppStorage("MacFSW.ShowsInspector") private var showsInspector = true

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
        }
        .inspector(isPresented: inspectorIsPresented) {
            InspectorView(event: model.monitor.selectedEvent, isLoading: model.monitor.selectedEventIsLoading)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 640)
        }
        .animation(.easeInOut(duration: 0.16), value: model.selectedPage)
        .toolbar { MainToolbar(model: model, inspectorIsPresented: inspectorIsPresented) }
        .navigationTitle(model.session.research.name)
        .navigationSubtitle(model.windowSubtitle)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.last(where: { $0.pathExtension == MacFSWSessionArchive.nativeExtension }) else {
                return false
            }
            model.openSession(at: url)
            return true
        }
    }

    /// The inspector belongs to the monitor: it follows the user's toggle
    /// there and stays out of the way on other pages.
    private var inspectorIsPresented: Binding<Bool> {
        Binding(
            get: { showsInspector && model.selectedPage == .monitor },
            set: { if model.selectedPage == .monitor { showsInspector = $0 } }
        )
    }
}

struct StatusBar: View {
    @Environment(MacFSWAppCoordinator.self) private var model

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

            Text("\(model.session.captureStats.deliveredEvents) captured")
                .monospacedDigit()
            Text("\(model.monitor.visibleEventCount) shown")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if model.session.captureStats.droppedEvents > 0 {
                Text("\(model.session.captureStats.droppedEvents) dropped")
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
            if model.session.captureState == .recording {
                Label(tableRefreshTitle, systemImage: tableRefreshSymbol)
                    .foregroundStyle(tableRefreshColor)
                    .frame(width: 68, alignment: .leading)
            }
            if model.monitor.followMode == .paused, model.monitor.unseenEventCount > 0 {
                Text("\(model.monitor.unseenEventCount) new below")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            if let error = model.errorMessage {
                ErrorStatusButton(message: error) {
                    model.errorMessage = nil
                }
            }
            if model.extensionStatus.installState == .ready {
                Label(model.extensionStatus.runningVersion.map { "Extension \($0.description)" } ?? "Extension ready", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .help(model.extensionStatus.installMessage)
            }
            if let lastUpdatedAt = model.monitor.lastUpdatedAt {
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
        switch model.session.captureState {
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
        model.monitor.followMode == .live ? "Live" : "Paused"
    }

    private var tableRefreshSymbol: String {
        model.monitor.followMode == .live ? "dot.radiowaves.left.and.right" : "pause.circle"
    }

    private var tableRefreshColor: Color {
        model.monitor.followMode == .live ? .green : .orange
    }
}


/// The latest error, truncated in the status bar; click for the full text.
private struct ErrorStatusButton: View {
    let message: String
    let onDismiss: () -> Void
    @State private var showsDetails = false

    var body: some View {
        Button {
            showsDetails.toggle()
        } label: {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .help("Show the full error")
        .popover(isPresented: $showsDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                ScrollView {
                    Text(message)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                    Spacer()
                    Button("Dismiss") {
                        showsDetails = false
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 420)
        }
    }
}
