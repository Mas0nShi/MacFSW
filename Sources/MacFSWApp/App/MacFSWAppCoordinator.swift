import AppKit
import MacFSWAnalysis
import MacFSWCore
import Observation

/// The app's root model. Feature stores own their state and logic; the
/// coordinator wires them together and handles actions that span features
/// — replacing the session, routing a process selection to Monitor or
/// Analysis, and syncing capture failures with System Extension status.
@MainActor
@Observable
final class MacFSWAppCoordinator {
    var selectedPage: MacFSWNavigationPage
    var errorMessage: String?

    let preferences: AppPreferencesStore
    let session: SessionStore
    let monitor: MonitorStore
    let processSidebar: ProcessSidebarStore
    let extensionStatus: SystemExtensionStatusStore
    let analysis: AnalysisStore
    let analysisTemplates: AnalysisTemplateStore
    let queryHistory: QueryHistoryStore
    let log: AppLogStore

    @ObservationIgnored
    let environment: MacFSWAppEnvironment

    init(environment: MacFSWAppEnvironment = .live) {
        self.environment = environment
        preferences = AppPreferencesStore(settingsStore: environment.settingsStore)
        processSidebar = ProcessSidebarStore(includeExitedProcesses: preferences.defaultIncludeExitedProcesses)
        extensionStatus = SystemExtensionStatusStore(installer: environment.extensionInstaller)
        analysis = AnalysisStore(llmClient: environment.llmClient)
        analysisTemplates = AnalysisTemplateStore(settingsStore: environment.settingsStore)
        queryHistory = QueryHistoryStore()
        log = AppLogStore()
        session = SessionStore(research: Self.makeResearchSession(appVersion: environment.appVersion), client: environment.captureClient)
        monitor = MonitorStore(eventStore: session.eventStore, processSidebar: processSidebar, queryHistory: queryHistory)
        selectedPage = preferences.defaultStartupPage
        wireStores()
        listenForExtensionSetupRequests()
        log.record(.info, "App coordinator initialized.", category: "App")
    }

    /// `macfsw setup` launches the app with an argument, or notifies it
    /// when it is already running.
    private func listenForExtensionSetupRequests() {
        DistributedNotificationCenter.default().addObserver(
            forName: MacFSWExtensionSetupSignal.notification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setUpExtensionForCLI()
            }
        }
        if CommandLine.arguments.contains(MacFSWExtensionSetupSignal.launchArgument) {
            Task { setUpExtensionForCLI() }
        }
    }

    private func setUpExtensionForCLI() {
        log.record(.info, "Extension setup requested by macfsw.", category: "SystemExtension")
        NSApplication.shared.activate()
        activateSystemExtension()
    }

    static func makeResearchSession(appVersion: String) -> MacFSWResearchSession {
        MacFSWResearchSession(
            name: "Untitled Research Session",
            targetDescription: "Focused file-system mutation capture",
            metadata: MacFSWSessionMetadata(appVersion: appVersion)
        )
    }

    private func wireStores() {
        let reportError: (any Error) -> Void = { [weak self] error in
            self?.reportError(error)
        }
        preferences.onError = reportError
        analysisTemplates.onError = reportError
        monitor.onError = reportError
        extensionStatus.onErrorMessage = { [weak self] message in
            self?.errorMessage = message
            self?.log.record(.error, message, category: "SystemExtension")
        }
        extensionStatus.onActivated = { [weak self] in
            Task { await self?.waitForActivatedExtension() }
        }
        session.onEvents = { [weak self] events in
            self?.ingest(events)
        }
        session.onCaptureFailure = { [weak self] error in
            self?.handleCaptureFailure(error)
        }
        session.onCaptureStopped = { [weak self] in
            self?.monitor.captureStopped()
        }
        session.onCleared = { [weak self] in
            // In stream order: batches after this one are new, so resetting
            // here cannot drop any.
            self?.resetViewsAfterClear()
        }
    }

    func reportError(_ error: any Error, category: String = "Error", metadata: [String: String] = [:]) {
        guard !ErrorPresentation.isCancellationError(error) else {
            return
        }
        let message = error.userFacingMessage
        log.record(.error, message, category: category, error: error, metadata: metadata)
        errorMessage = message
    }

    func prepareForTermination() async {
        monitor.cancelAllWork()
        analysis.cancelTask()
        processSidebar.cancelPublishing()
        do {
            try await session.close()
        } catch {
            reportError(error)
        }
    }

    // MARK: - Cross-feature presentation

    var statusText: String {
        switch session.captureState {
        case .recording: "Recording"
        case .connecting: "Connecting"
        case .stopping: "Stopping"
        case .failed: "Failed"
        case .degraded: "Degraded"
        case .stopped: "Stopped"
        case .idle: "Idle"
        }
    }

    var captureStatusDetail: String {
        if session.isReadOnly {
            return "Opened session, read-only. Start a new session to record."
        }
        return switch session.captureState {
        case .recording:
            monitor.followMode == .live ? "Following live events." : "View is paused; capture is still running."
        case .connecting:
            "Opening Endpoint Security stream."
        case .stopping:
            "Writing the last captured events."
        case .failed, .degraded:
            session.captureHealth.message
        case .stopped, .idle:
            session.captureStats.deliveredEvents > 0
                ? "\(session.captureStats.deliveredEvents) events captured."
                : "Capture service is idle."
        }
    }

    var recordButtonTitle: String {
        if session.captureState == .recording {
            return "Stop"
        }
        if session.captureHealth.fullDiskAccessHint {
            return "Open Full Disk Access"
        }
        return extensionStatus.installState == .ready ? "Record" : "Enable Extension"
    }

    var recordButtonSymbol: String {
        if session.captureState == .recording {
            return "stop.circle.fill"
        }
        if session.captureHealth.fullDiskAccessHint {
            return "lock.shield"
        }
        return extensionStatus.installState == .ready ? "record.circle" : "puzzlepiece.extension"
    }

    /// Where the session lives and whether it is safe, under the title.
    var windowSubtitle: String {
        let events = session.captureStats.deliveredEvents
        let count = events == 1 ? "1 event" : "\(events.formatted()) events"
        if session.captureState == .recording {
            return "Recording · \(count)"
        }
        if let file = session.fileURL {
            return "\(file.lastPathComponent) · \(count) · Read-only"
        }
        if session.hasUnsavedEvents {
            return "\(count) · Not saved"
        }
        return events == 0 ? "No events" : count
    }

    var shouldShowJumpToLive: Bool {
        session.captureState == .recording
            && monitor.followMode == .paused
    }

    var selectedAnalysisProcess: MacFSWProcessSummary? {
        analysis.selectedProcessID.flatMap(processSidebar.summary(for:))
    }

    var canRunAnalysis: Bool {
        selectedAnalysisProcess != nil && !analysis.isRunning
    }
}
