import AppKit
import Darwin
import MacFSWAnalysis
import MacFSWCore
import MarkdownView
import SwiftUI
import SystemExtensions
import UniformTypeIdentifiers

@main
struct MacFSWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = MacFSWAppModel()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear {
                    appDelegate.model = model
                }
                .task {
                    await model.refreshHealth()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    model.newSession()
                }
                .keyboardShortcut("n")

                Button("Open Session...") {
                    model.openSession()
                }
                .keyboardShortcut("o")

                Divider()

                Button("Save Session...") {
                    model.saveSession()
                }
                .keyboardShortcut("s")
            }

            CommandGroup(replacing: .windowArrangement) {}

            CommandGroup(replacing: .help) {
                Button("MacFSW User Manual") {
                    openWindow(id: MacFSWHelpWindow.userManualID)
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 760, height: 540)
        }

        Window("MacFSW User Manual", id: MacFSWHelpWindow.userManualID) {
            UserManualView()
                .frame(minWidth: 760, minHeight: 640)
        }
        .defaultSize(width: 860, height: 760)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MacFSWAppModel?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateNow
        }
        isTerminating = true
        Task { [weak self] in
            await self?.model?.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum MacFSWFollowMode: String, Equatable {
    case live
    case paused
    case frozen

    var title: String {
        switch self {
        case .live: "Live"
        case .paused: "Paused"
        case .frozen: "Frozen"
        }
    }

    var symbolName: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .paused: "pause.circle"
        case .frozen: "snowflake"
        }
    }
}

enum MacFSWNavigationPage: String, CaseIterable, Identifiable, Sendable {
    case monitor
    case analysis

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor: "Monitor"
        case .analysis: "Analysis"
        }
    }

    var symbolName: String {
        switch self {
        case .monitor: "waveform.path.ecg"
        case .analysis: "sparkles.rectangle.stack"
        }
    }

    var isBeta: Bool {
        switch self {
        case .monitor: false
        case .analysis: true
        }
    }
}

private enum MacFSWUILayout {
    static let pageHeaderHeight: CGFloat = 62
}

enum MacFSWProcessLifecycle: String, Equatable, Sendable {
    case running
    case exited
    case unknown

    var title: String {
        switch self {
        case .running: "Running"
        case .exited: "Exited"
        case .unknown: "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "circle.fill"
        case .exited: "circle"
        case .unknown: "questionmark.circle"
        }
    }
}

struct MacFSWProcessSummary: Identifiable, Equatable, Sendable {
    var id: String
    var processName: String
    var pid: Int32
    var auditToken: String
    var executablePath: String
    var signingSummary: String
    var uid: UInt32
    var gid: UInt32
    var eventCount: Int
    var lastEventNS: UInt64
    var isPlatformBinary: Bool
    var identityCount: Int
    var lifecycle: MacFSWProcessLifecycle

    var displayName: String {
        "\(processName)(\(pid))"
    }

    var filterIdentity: MacFSWProcessFilterIdentity {
        MacFSWProcessFilterIdentity(pid: pid, auditToken: auditToken, executablePath: executablePath)
    }

    var isAppleSigned: Bool {
        signingSummary.lowercased().hasPrefix("com.apple.")
    }

    var processIconSymbolName: String {
        isAppleSigned ? "apple.logo" : "app"
    }

    init(
        id: String,
        processName: String,
        pid: Int32,
        auditToken: String,
        executablePath: String,
        signingSummary: String,
        uid: UInt32,
        gid: UInt32,
        eventCount: Int,
        lastEventNS: UInt64,
        isPlatformBinary: Bool,
        identityCount: Int = 1,
        lifecycle: MacFSWProcessLifecycle = .unknown
    ) {
        self.id = id
        self.processName = processName
        self.pid = pid
        self.auditToken = auditToken
        self.executablePath = executablePath
        self.signingSummary = signingSummary
        self.uid = uid
        self.gid = gid
        self.eventCount = eventCount
        self.lastEventNS = lastEventNS
        self.isPlatformBinary = isPlatformBinary
        self.identityCount = identityCount
        self.lifecycle = lifecycle
    }

    init(coreSummary: MacFSWProcessEventSummary) {
        self.init(
            id: coreSummary.id,
            processName: coreSummary.processName,
            pid: coreSummary.pid,
            auditToken: coreSummary.auditToken,
            executablePath: coreSummary.executablePath,
            signingSummary: coreSummary.signingSummary,
            uid: coreSummary.uid,
            gid: coreSummary.gid,
            eventCount: coreSummary.eventCount,
            lastEventNS: coreSummary.lastEventNS,
            isPlatformBinary: coreSummary.isPlatformBinary,
            identityCount: coreSummary.identityCount
        )
    }
}

struct MacFSWProcessGroupSummary: Identifiable, Equatable, Sendable {
    var id: String { processName }
    var processName: String
    var summaries: [MacFSWProcessSummary]
    var eventCount: Int
    var lastEventNS: UInt64
    var exitedCount: Int

    var instanceCount: Int {
        summaries.count
    }

    var processIconSymbolName: String {
        summaries.allSatisfy(\.isAppleSigned) ? "apple.logo" : "app"
    }
}

enum MacFSWOperationBucket: String, CaseIterable, Identifiable, Sendable {
    case read
    case create
    case write
    case rename
    case delete
    case metadata
    case link
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: "READ"
        case .create: "CREATE"
        case .write: "WRITE"
        case .rename: "RENAME"
        case .delete: "DELETE"
        case .metadata: "METADATA"
        case .link: "LINK"
        case .unknown: "UNKNOWN"
        }
    }

    var symbolName: String {
        switch self {
        case .read: "doc.text.magnifyingglass"
        case .create: "doc.badge.plus"
        case .write: "square.and.pencil"
        case .rename: "arrow.triangle.2.circlepath"
        case .delete: "trash"
        case .metadata: "tag"
        case .link: "link"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .read: .blue
        case .create: .teal
        case .write: .indigo
        case .rename: .purple
        case .delete: .red
        case .metadata: .orange
        case .link: .mint
        case .unknown: .secondary
        }
    }

    static func bucket(for eventType: MacFSWEventType) -> MacFSWOperationBucket {
        switch eventType {
        case .open, .close:
            .read
        case .create:
            .create
        case .write, .clone, .copyfile, .truncate:
            .write
        case .rename, .exchangedata:
            .rename
        case .unlink:
            .delete
        case .chmod, .chown, .setflags, .setacl, .setextattr, .deleteextattr, .utimes:
            .metadata
        case .link:
            .link
        case .unknown:
            .unknown
        }
    }
}

struct MacFSWOperationSummary: Identifiable, Equatable, Sendable {
    var bucket: MacFSWOperationBucket
    var eventCount: Int

    var id: String { bucket.id }
}

struct MacFSWAnalysisResult: Identifiable, Equatable, Sendable {
    var id = UUID()
    var processID: MacFSWProcessSummary.ID
    var processDisplayName: String
    var createdAt: Date
    var durationSeconds: Double
    var scope: String
    var providerSummary: String
    var eventCount: Int
    var payloadEventCount: Int
    var pathCount: Int
    var operationCount: Int
    var markdown: String
}

private extension MacFSWProcessSummary {
    static func id(for event: MacFSWFileEvent) -> String {
        event.process.filterIdentity.stableID
    }

    init(event: MacFSWFileEvent, eventCount: Int) {
        self.init(
            id: Self.id(for: event),
            processName: event.process.processName,
            pid: event.process.pid,
            auditToken: event.process.auditToken,
            executablePath: event.process.executablePath,
            signingSummary: event.process.signingID ?? event.process.teamID ?? "-",
            uid: event.uid,
            gid: event.gid,
            eventCount: eventCount,
            lastEventNS: event.timestampNS,
            isPlatformBinary: event.process.isPlatformBinary,
            identityCount: 1
        )
    }
}

private extension Collection where Element == MacFSWProcessSummary {
    func sortedForDisplay() -> [MacFSWProcessSummary] {
        sorted { lhs, rhs in
            if lhs.eventCount != rhs.eventCount {
                return lhs.eventCount > rhs.eventCount
            }
            if lhs.lastEventNS != rhs.lastEventNS {
                return lhs.lastEventNS > rhs.lastEventNS
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

enum MacFSWWildcard {
    static func matches(_ pattern: String, value: String) -> Bool {
        let pattern = Array(pattern.lowercased())
        let value = Array(value.lowercased())
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var starValueIndex = 0

        while valueIndex < value.count {
            if patternIndex < pattern.count,
               (pattern[patternIndex] == "?" || pattern[patternIndex] == value[valueIndex]) {
                patternIndex += 1
                valueIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                starIndex = patternIndex
                starValueIndex = valueIndex
                patternIndex += 1
            } else if let starIndex {
                patternIndex = starIndex + 1
                starValueIndex += 1
                valueIndex = starValueIndex
            } else {
                return false
            }
        }

        while patternIndex < pattern.count, pattern[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == pattern.count
    }
}

struct MacFSWConnectionTestError: Equatable {
    var title: String
    var message: String
    var diagnostic: String
}

enum MacFSWConnectionTestState: Equatable {
    case idle
    case testing
    case succeeded(String)
    case failed(MacFSWConnectionTestError)

    var badgeTitle: String {
        switch self {
        case .idle:
            "Not Tested"
        case .testing:
            "Testing"
        case .succeeded:
            "OK"
        case .failed:
            "Failed"
        }
    }

    var badgeSymbolName: String {
        switch self {
        case .idle:
            "circle"
        case .testing:
            "clock"
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .idle:
            .secondary
        case .testing:
            .secondary
        case .succeeded:
            .green
        case .failed:
            .orange
        }
    }
}

@MainActor
final class MacFSWAppModel: ObservableObject {
    @Published var session: MacFSWResearchSession
    @Published var selectedPage: MacFSWNavigationPage = .monitor
    @Published var visibleEventCount = 0
    @Published var rowCacheVersion = 0
    @Published var rowCacheResetSerial = 0
    @Published var tableResetSerial = 0
    @Published var selectedEventID: UUID?
    @Published var selectedRow: Int?
    @Published var selectedEvent: MacFSWFileEvent?
    @Published var selectedEventIsLoading = false
    @Published var queryText = ""
    @Published var captureState: MacFSWCaptureState = .idle
    @Published var captureHealth = MacFSWCaptureHealth()
    @Published var captureStats = MacFSWCaptureStats()
    @Published var extensionInstallState: MacFSWSystemExtensionInstallState = .unknown
    @Published var extensionInstallMessage = "Checking System Extension readiness."
    @Published var followMode: MacFSWFollowMode = .live
    @Published var unseenEventCount = 0
    @Published var isViewingLiveEdge = true
    @Published var scrollToLiveSerial = 0
    @Published var selectionResetSerial = 0
    @Published var errorMessage: String?
    @Published var lastUpdatedAt: Date?
    @Published var processSearchText = "" {
        didSet {
            scheduleProcessSummaryPublish()
        }
    }
    @Published var processSummaries: [MacFSWProcessSummary] = []
    @Published var filteredProcessSummaries: [MacFSWProcessSummary] = []
    @Published var filteredProcessGroups: [MacFSWProcessGroupSummary] = []
    @Published var operationSummaries: [MacFSWOperationSummary] = []
    @Published var expandedProcessGroupIDs: Set<String> = []
    @Published var includeExitedProcesses = true {
        didSet {
            publishProcessSummaries()
        }
    }
    @Published var selectedProcessID: MacFSWProcessSummary.ID?
    @Published var selectedAnalysisProcessID: MacFSWProcessSummary.ID?
    @Published var isAnalysisRunning = false
    @Published var streamingAnalysisMarkdown = ""
    @Published var analysisStatusText = "Select a process to analyze."
    @Published var analysisRunError: MacFSWConnectionTestError?
    @Published var analysisResults: [MacFSWAnalysisResult] = []
    @Published var selectedAnalysisID: MacFSWAnalysisResult.ID?
    @Published var llmSettings = MacFSWLLMSettings() {
        didSet {
            persistLLMSettings()
        }
    }
    @Published var llmConnectionTestState: MacFSWConnectionTestState = .idle
    @Published var defaultStartupPage: MacFSWNavigationPage = .monitor {
        didSet {
            UserDefaults.standard.set(defaultStartupPage.rawValue, forKey: Self.defaultStartupPageKey)
        }
    }
    @Published var defaultIncludeExitedProcesses = true {
        didSet {
            guard !isLoadingStoredSettings else {
                return
            }
            UserDefaults.standard.set(defaultIncludeExitedProcesses, forKey: Self.includeExitedProcessesDefaultKey)
        }
    }
    @Published var isApplyingFilter = false

    private var eventStore: MacFSWSQLiteEventStore
    private let captureClient: MacFSWCaptureClient
    private let extensionInstaller: SystemExtensionInstaller
    private let settingsStore: MacFSWSettingsStore
    private let llmClient: MacFSWLLMClient
    private var captureHandle: MacFSWCaptureHandle?
    private var refreshTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var selectedEventLoadTask: Task<Void, Never>?
    private var selectedEventLoadGeneration = 0
    private var processSummaryPublishTask: Task<Void, Never>?
    private var snapshotCleanupTask: Task<Void, Never>?
    private var retiredSnapshotIDs: Set<String> = []
    private var pendingCaptureStats: MacFSWCaptureStats?
    private var activeQuery = MacFSWEventQuery()
    private var activeSnapshot: MacFSWEventResultSnapshot?
    private var processSummaryIndex: [MacFSWProcessSummary.ID: MacFSWProcessSummary] = [:]
    private let rowPageSize = 256
    private let maxCachedRowPages = 96
    private let maxDirectAppendCacheRows = 1_024
    private var rowCache: [Int: MacFSWEventRowSummary] = [:]
    private var loadedRowPages: Set<Int> = []
    private var inFlightRowPages: Set<Int> = []
    private var rowLoadTasks: [Int: Task<Void, Never>] = [:]
    private var rowPageAccessTicks: [Int: Int] = [:]
    private var rowPageAccessTick = 0
    private var lastRequestedRowRange: Range<Int> = 0..<0
    private var totalMatchingEventCount = 0
    private var pendingVisibleMatchCount = 0
    private var pendingVisibleRowSummaries: [MacFSWEventRowSummary] = []
    private var queryGeneration = 0
    private var analysisGeneration = 0
    private var isLoadingStoredSettings = false
    private static let includeExitedProcessesDefaultKey = "MacFSW.IncludeExitedProcesses.Default"
    private static let defaultStartupPageKey = "MacFSW.DefaultStartupPage"

    init() {
        let xpcServiceName = Bundle.main.object(forInfoDictionaryKey: "MacFSWXPCServiceName") as? String
        self.captureClient = MacFSWXPCCaptureClient(
            serviceName: xpcServiceName.flatMap { $0.isEmpty ? nil : $0 } ?? MacFSWXPCDefaults.serviceName
        )
        self.extensionInstaller = SystemExtensionInstaller.shared
        self.settingsStore = .shared
        self.llmClient = MacFSWLLMClient()
        let initialSession = MacFSWResearchSession(
            name: "Untitled Research Session",
            targetDescription: "Focused file-system mutation capture"
        )
        try? MacFSWSQLiteEventStore.cleanupStaleTemporaryStores()
        self.session = initialSession
        self.eventStore = try! MacFSWSQLiteEventStore.temporary(session: initialSession)
        loadStoredSettings()
        self.extensionInstaller.onStateChange = { [weak self] state, message in
            self?.extensionInstallState = state
            self?.extensionInstallMessage = message
            if state == .failed {
                self?.errorMessage = message
            }
            if state == .ready {
                Task { [weak self] in
                    await self?.refreshHealth()
                }
            }
        }
    }

    private func loadStoredSettings() {
        isLoadingStoredSettings = true
        llmSettings = settingsStore.loadLLMSettings()
        let includeExitedByDefault = UserDefaults.standard.object(forKey: Self.includeExitedProcessesDefaultKey) as? Bool ?? true
        defaultIncludeExitedProcesses = includeExitedByDefault
        includeExitedProcesses = includeExitedByDefault
        if let rawPage = UserDefaults.standard.string(forKey: Self.defaultStartupPageKey),
           let page = MacFSWNavigationPage(rawValue: rawPage) {
            defaultStartupPage = page
            selectedPage = page
        }
        isLoadingStoredSettings = false
    }

    private func persistLLMSettings() {
        guard !isLoadingStoredSettings else {
            return
        }
        do {
            try settingsStore.saveLLMSettings(llmSettings)
            if !isTestingLLMConnection {
                llmConnectionTestState = .idle
            }
        } catch {
            reportError(error)
        }
    }

    private func cleanupStoreIfOwned(_ store: MacFSWSQLiteEventStore) async {
        do {
            try await store.cleanupBackingStore()
        } catch {
            reportError(error)
        }
    }

    func prepareForTermination() async {
        stopCapture()
        renderTask?.cancel()
        refreshTask?.cancel()
        filterTask?.cancel()
        analysisTask?.cancel()
        processSummaryPublishTask?.cancel()
        cancelSelectedEventLoad()
        cancelSnapshotCleanup()
        cancelRowLoads()
        await cleanupStoreIfOwned(eventStore)
    }

    var statusText: String {
        switch captureState {
        case .recording:
            "Recording"
        case .connecting:
            "Connecting"
        case .stopping:
            "Stopping"
        case .failed:
            "Failed"
        case .degraded:
            "Degraded"
        case .stopped:
            "Stopped"
        case .idle:
            "Idle"
        }
    }

    var captureStatusDetail: String {
        switch captureState {
        case .recording:
            followMode == .live ? "Following live events." : "View is paused; capture is still running."
        case .connecting:
            "Opening Endpoint Security stream."
        case .stopping:
            "Stopping capture stream."
        case .failed, .degraded:
            captureHealth.message
        case .stopped, .idle:
            captureStats.deliveredEvents > 0
                ? "\(captureStats.deliveredEvents) events captured."
                : "Capture service is idle."
        }
    }

    var shouldShowJumpToLive: Bool {
        captureState == .recording && ((followMode != .live && unseenEventCount > 0) || !isViewingLiveEdge)
    }

    var jumpToLiveTitle: String {
        "Jump to Live"
    }

    var shouldShowInspector: Bool {
        selectedEventID != nil || selectedEvent != nil || selectedEventIsLoading
    }

    var filteredExitedProcessCount: Int {
        filteredProcessSummaries.filter { $0.lifecycle == .exited }.count
    }

    var selectedAnalysis: MacFSWAnalysisResult? {
        guard let selectedAnalysisID else { return nil }
        return analysisResults.first { $0.id == selectedAnalysisID }
    }

    var selectedAnalysisProcess: MacFSWProcessSummary? {
        guard let selectedAnalysisProcessID else {
            return nil
        }
        return processSummary(for: selectedAnalysisProcessID)
    }

    var canRunAnalysis: Bool {
        selectedAnalysisProcess != nil && !isAnalysisRunning
    }

    var isTestingLLMConnection: Bool {
        if case .testing = llmConnectionTestState {
            return true
        }
        return false
    }

    func newSession() {
        guard confirmSessionReplacement(
            title: "Start a New Session?",
            message: "The current session will be closed. Save it first if you want to keep captured events, filters, or analysis results."
        ) else {
            return
        }
        stopCapture()
        renderTask?.cancel()
        renderTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        filterTask?.cancel()
        filterTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        processSummaryPublishTask?.cancel()
        processSummaryPublishTask = nil
        cancelSelectedEventLoad()
        cancelSnapshotCleanup()
        cancelRowLoads()
        Task {
            do {
                let newSession = MacFSWResearchSession(
                    name: "Untitled Research Session",
                    targetDescription: "Focused file-system mutation capture"
                )
                let newStore = try MacFSWSQLiteEventStore.temporary(session: newSession)
                let oldStore = await MainActor.run { () -> MacFSWSQLiteEventStore in
                    let oldStore = eventStore
                    eventStore = newStore
                    session = newSession
                    visibleEventCount = 0
                    totalMatchingEventCount = 0
                    resetRowCache(resetTable: true)
                    selectedEventID = nil
                    selectedRow = nil
                    selectedEvent = nil
                    selectedEventIsLoading = false
                    isApplyingFilter = false
                    queryText = ""
                    activeQuery = MacFSWEventQuery()
                    activeSnapshot = nil
                    processSearchText = ""
                    includeExitedProcesses = defaultIncludeExitedProcesses
                    operationSummaries = []
                    clearProcessSummaries()
                    selectedProcessID = nil
                    selectedAnalysisProcessID = nil
                    isAnalysisRunning = false
                    streamingAnalysisMarkdown = ""
                    analysisStatusText = "Select a process to analyze."
                    analysisRunError = nil
                    analysisResults = []
                    selectedAnalysisID = nil
                    selectedPage = .monitor
                    followMode = .live
                    unseenEventCount = 0
                    isViewingLiveEdge = true
                    scrollToLiveSerial += 1
                    selectionResetSerial += 1
                    errorMessage = nil
                    lastUpdatedAt = Date()
                    return oldStore
                }
                await cleanupStoreIfOwned(oldStore)
            } catch {
                await MainActor.run {
                    reportError(error)
                }
            }
        }
    }

    private func confirmSessionReplacement(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "New Session")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func refreshHealth() async {
        do {
            let health = try await captureClient.health()
            captureHealth = health
            captureStats = health.stats
            if health.fullDiskAccessHint {
                extensionInstallState = .failed
                extensionInstallMessage = health.message
            } else {
                extensionInstallState = .ready
                extensionInstallMessage = health.endpointSecurityAuthorized
                    ? "MacFSW Endpoint Extension is reachable and has Endpoint Security permission."
                    : "MacFSW Endpoint Extension is reachable."
            }
            if captureState != .recording {
                captureState = health.state
            }
            if !health.fullDiskAccessHint {
                extensionInstaller.checkInstalledVersion()
            }
        } catch {
            guard !isCancellationError(error) else {
                return
            }
            if extensionInstallState != .activating && extensionInstallState != .needsApproval {
                extensionInstallState = .notReady
                extensionInstallMessage = "MacFSW Endpoint Extension is not installed, not approved, or not reachable."
            }
            captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAvailable: true,
                endpointSecurityAuthorized: false,
                message: userFacingMessage(error)
            )
            reportError(error)
        }
    }

    func recordButtonTapped() {
        if captureState == .recording {
            stopCapture()
            return
        }

        guard extensionInstallState == .ready else {
            if captureHealth.fullDiskAccessHint {
                openFullDiskAccessSettings()
                return
            }
            activateSystemExtension()
            return
        }

        startCapture()
    }

    func activateSystemExtension() {
        errorMessage = nil
        extensionInstaller.activate()
    }

    func openSystemExtensionSettings() {
        extensionInstaller.openLoginItemsSettings()
    }

    func openFullDiskAccessSettings() {
        extensionInstaller.openFullDiskAccessSettings()
    }

    func checkSystemExtensionAgain() {
        extensionInstaller.resetSubmission()
        Task {
            await refreshHealth()
        }
    }

    func startCapture() {
        guard captureHandle == nil else {
            return
        }
        captureState = .connecting
        followMode = .live
        unseenEventCount = 0
        isViewingLiveEdge = true
        scrollToLiveSerial += 1
        errorMessage = nil

        Task {
            do {
                let config = session.captureConfig
                let handle = try await captureClient.openCaptureStream(
                    config: config,
                    onBatch: { [weak self] batch in
                        Task { @MainActor [weak self] in
                            await self?.ingest(batch)
                        }
                    },
                    onFinish: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.captureDidFinish(error)
                        }
                    }
                )

                captureHandle = handle
                captureState = .recording
            } catch {
                captureState = .failed
                handleCaptureStartFailure(error)
            }
        }
    }

    func stopCapture() {
        guard let captureHandle else {
            captureState = .idle
            return
        }
        captureState = .stopping
        captureHandle.stop()
        self.captureHandle = nil
        captureState = .stopped
        followMode = .paused
        unseenEventCount = 0
        isViewingLiveEdge = true
        pendingCaptureStats = nil
    }

    func clearView() {
        renderTask?.cancel()
        renderTask = nil
        filterTask?.cancel()
        filterTask = nil
        cancelSelectedEventLoad()
        cancelSnapshotCleanup()
        cancelRowLoads()
        Task {
            do {
                try await eventStore.clear()
                await MainActor.run {
                    visibleEventCount = 0
                    totalMatchingEventCount = 0
                    resetRowCache(resetTable: true)
                    selectedEventID = nil
                    selectedRow = nil
                    selectedEvent = nil
                    selectedEventIsLoading = false
                    isApplyingFilter = false
                    activeQuery = MacFSWQueryParser.parse(queryText)
                    activeSnapshot = nil
                    operationSummaries = []
                    clearProcessSummaries()
                    selectedProcessID = nil
                    selectedAnalysisProcessID = nil
                    streamingAnalysisMarkdown = ""
                    analysisStatusText = "Select a process to analyze."
                    analysisRunError = nil
                    followMode = .live
                    unseenEventCount = 0
                    isViewingLiveEdge = true
                    scrollToLiveSerial += 1
                    selectionResetSerial += 1
                    errorMessage = nil
                    lastUpdatedAt = Date()
                }
            } catch {
                await MainActor.run {
                    reportError(error)
                }
            }
        }
    }

    private func resetVisibleStateForLoadedStore() {
        filterTask?.cancel()
        filterTask = nil
        cancelAnalysis()
        cancelSelectedEventLoad()
        cancelSnapshotCleanup()
        visibleEventCount = 0
        totalMatchingEventCount = 0
        resetRowCache(resetTable: true)
        selectedEventID = nil
        selectedRow = nil
        selectedEvent = nil
        selectedEventIsLoading = false
        isApplyingFilter = false
        activeQuery = MacFSWEventQuery()
        activeSnapshot = nil
        processSearchText = ""
        includeExitedProcesses = defaultIncludeExitedProcesses
        operationSummaries = []
        clearProcessSummaries()
        selectedProcessID = nil
        selectedAnalysisProcessID = nil
        streamingAnalysisMarkdown = ""
        analysisStatusText = "Select a process to analyze."
        analysisRunError = nil
        selectedPage = .monitor
        followMode = .paused
        unseenEventCount = 0
        isViewingLiveEdge = true
        selectionResetSerial += 1
        captureState = .idle
    }

    private func refreshProcessSummariesFromStore() async {
        do {
            let summaries = try await eventStore.processSummaries()
                .map(MacFSWProcessSummary.init(coreSummary:))
                .sortedForDisplay()
            replaceProcessSummaries(summaries)
        } catch {
            reportError(error)
        }
    }

    private func updateProcessSummaries(with events: [MacFSWFileEvent]) {
        guard !events.isEmpty else {
            return
        }

        for event in events {
            let id = MacFSWProcessSummary.id(for: event)
            var summary = processSummaryIndex[id] ?? MacFSWProcessSummary(event: event, eventCount: 0)
            summary.processName = event.process.processName
            summary.pid = event.process.pid
            summary.auditToken = event.process.auditToken
            summary.executablePath = event.process.executablePath
            summary.signingSummary = event.process.signingID ?? event.process.teamID ?? "-"
            summary.uid = event.uid
            summary.gid = event.gid
            summary.eventCount += 1
            summary.lastEventNS = max(summary.lastEventNS, event.timestampNS)
            summary.isPlatformBinary = event.process.isPlatformBinary
            let identityKey = event.process.auditToken.isEmpty
                ? "exec:\(event.process.executablePath)"
                : "audit:\(event.process.auditToken)"
            if summary.auditToken != event.process.auditToken || summary.executablePath != event.process.executablePath {
                summary.identityCount = max(summary.identityCount, 2)
            } else if !identityKey.isEmpty {
                summary.identityCount = max(summary.identityCount, 1)
            }
            processSummaryIndex[id] = summary
        }

        scheduleProcessSummaryPublish()
        if let selectedProcessID, processSummaryIndex[selectedProcessID] == nil {
            self.selectedProcessID = nil
        }
        if let selectedAnalysisProcessID, processSummaryIndex[selectedAnalysisProcessID] == nil {
            self.selectedAnalysisProcessID = nil
        }
    }

    private func replaceProcessSummaries(_ summaries: [MacFSWProcessSummary]) {
        processSummaryIndex = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.lastEventNS >= rhs.lastEventNS ? lhs : rhs
        })
        publishProcessSummaries()
    }

    private func clearProcessSummaries() {
        processSummaryPublishTask?.cancel()
        processSummaryPublishTask = nil
        processSummaryIndex.removeAll(keepingCapacity: true)
        processSummaries = []
        filteredProcessSummaries = []
        filteredProcessGroups = []
        expandedProcessGroupIDs.removeAll(keepingCapacity: true)
        selectedAnalysisProcessID = nil
    }

    private func scheduleProcessSummaryPublish() {
        guard processSummaryPublishTask == nil else {
            return
        }
        processSummaryPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.processSummaryPublishTask = nil
                self?.publishProcessSummaries()
            }
        }
    }

    private func publishProcessSummaries() {
        processSummaryPublishTask?.cancel()
        processSummaryPublishTask = nil
        let summaries = processSummaryIndex.values
            .map { summary in
                var summary = summary
                summary.lifecycle = Self.lifecycle(for: summary.pid)
                return summary
            }
            .sortedForDisplay()
        processSummaries = summaries
        let filtered = filteredProcessSummaries(from: summaries)
        filteredProcessSummaries = filtered
        filteredProcessGroups = processGroups(from: filtered)
        if let selectedProcessID, processSummaryIndex[selectedProcessID] == nil {
            self.selectedProcessID = nil
        }
    }

    private static func lifecycle(for pid: Int32) -> MacFSWProcessLifecycle {
        guard pid > 0 else {
            return .unknown
        }
        errno = 0
        if kill(pid_t(pid), 0) == 0 || errno == EPERM {
            return .running
        }
        if errno == ESRCH {
            return .exited
        }
        return .unknown
    }

    private func processGroups(from summaries: [MacFSWProcessSummary]) -> [MacFSWProcessGroupSummary] {
        Dictionary(grouping: summaries, by: \.processName)
            .map { processName, summaries in
                MacFSWProcessGroupSummary(
                    processName: processName,
                    summaries: summaries.sortedForDisplay(),
                    eventCount: summaries.reduce(0) { $0 + $1.eventCount },
                    lastEventNS: summaries.map(\.lastEventNS).max() ?? 0,
                    exitedCount: summaries.filter { $0.lifecycle == .exited }.count
                )
            }
            .sorted { lhs, rhs in
                if lhs.eventCount != rhs.eventCount {
                    return lhs.eventCount > rhs.eventCount
                }
                if lhs.lastEventNS != rhs.lastEventNS {
                    return lhs.lastEventNS > rhs.lastEventNS
                }
                return lhs.processName.localizedCaseInsensitiveCompare(rhs.processName) == .orderedAscending
            }
    }

    private func filteredProcessSummaries(from summaries: [MacFSWProcessSummary]) -> [MacFSWProcessSummary] {
        filterProcessSummaries(summaries, query: processSearchText, includeExited: includeExitedProcesses)
    }

    private func filterProcessSummaries(
        _ summaries: [MacFSWProcessSummary],
        query rawQuery: String,
        includeExited: Bool
    ) -> [MacFSWProcessSummary] {
        let summaries = includeExited
            ? summaries
            : summaries.filter { $0.lifecycle != .exited }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return summaries
        }
        return summaries.filter { summary in
            let values = [
                summary.displayName,
                summary.processName,
                "\(summary.pid)",
                summary.executablePath,
                summary.signingSummary,
            ]
            if query.contains("*") || query.contains("?") {
                return values.contains { MacFSWWildcard.matches(query, value: $0) }
            }
            return values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func operationSummaries(from summaries: [MacFSWOperationEventSummary]) -> [MacFSWOperationSummary] {
        var counts: [MacFSWOperationBucket: Int] = [:]
        for summary in summaries {
            let bucket = MacFSWOperationBucket.bucket(for: summary.eventType)
            counts[bucket, default: 0] += summary.eventCount
        }
        return sortedOperationSummaries(from: counts)
    }

    private func applyOperationSummaryDelta(from rows: [MacFSWEventRowSummary]) {
        guard !rows.isEmpty else {
            return
        }
        var counts = Dictionary(uniqueKeysWithValues: operationSummaries.map { ($0.bucket, $0.eventCount) })
        for row in rows {
            let bucket = MacFSWOperationBucket.bucket(for: row.eventType)
            counts[bucket, default: 0] += 1
        }
        operationSummaries = sortedOperationSummaries(from: counts)
    }

    private func sortedOperationSummaries(from counts: [MacFSWOperationBucket: Int]) -> [MacFSWOperationSummary] {
        counts
            .filter { $0.value > 0 }
            .map { MacFSWOperationSummary(bucket: $0.key, eventCount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.eventCount != rhs.eventCount {
                    return lhs.eventCount > rhs.eventCount
                }
                let lhsIndex = MacFSWOperationBucket.allCases.firstIndex(of: lhs.bucket) ?? 0
                let rhsIndex = MacFSWOperationBucket.allCases.firstIndex(of: rhs.bucket) ?? 0
                return lhsIndex < rhsIndex
            }
    }

    func scheduleQueryRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else {
                return
            }
            await self?.refreshFilteredEvents()
        }
    }

    func refreshFilteredEvents(allowAutoSelection: Bool = false) async {
        await refreshFilteredEvents(using: nil, allowAutoSelection: allowAutoSelection)
    }

    func applySavedQuery(_ saved: MacFSWSavedQuery) {
        queryText = saved.query.text
        Task {
            var query = saved.query
            query.limit = 0
            await refreshFilteredEvents(using: query, allowAutoSelection: true)
        }
    }

    func applyProcessFilter(_ summary: MacFSWProcessSummary) {
        selectedProcessID = summary.id
        selectedPage = .monitor
        clearEventSelection()
        Task {
            await refreshFilteredEvents()
        }
    }

    func clearProcessFilter() {
        selectedProcessID = nil
        clearEventSelection()
        Task {
            await refreshFilteredEvents()
        }
    }

    func toggleProcessGroup(_ id: String) {
        if expandedProcessGroupIDs.contains(id) {
            expandedProcessGroupIDs.remove(id)
        } else {
            expandedProcessGroupIDs.insert(id)
        }
    }

    func selectAnalysisProcess(_ summary: MacFSWProcessSummary) {
        selectedAnalysisProcessID = summary.id
        selectedAnalysisID = nil
        selectedPage = .analysis
        if !isAnalysisRunning {
            streamingAnalysisMarkdown = ""
            analysisRunError = nil
            analysisStatusText = "\(summary.displayName) selected."
        }
    }

    func selectSidebarProcess(_ summary: MacFSWProcessSummary) {
        switch selectedPage {
        case .monitor:
            applyProcessFilter(summary)
        case .analysis:
            selectAnalysisProcess(summary)
        }
    }

    func runAnalysis() {
        guard let target = selectedAnalysisProcess else {
            analysisStatusText = "Select a process to analyze."
            selectedPage = .analysis
            return
        }

        analysisTask?.cancel()
        analysisGeneration += 1
        let generation = analysisGeneration
        let settings = llmSettings
        let store = eventStore
        let client = llmClient
        let startedAt = Date()
        selectedPage = .analysis
        selectedAnalysisID = nil
        streamingAnalysisMarkdown = ""
        analysisRunError = nil
        isAnalysisRunning = true
        analysisStatusText = "Preparing \(target.displayName)..."

        analysisTask = Task { [weak self] in
            do {
                let query = MacFSWEventQuery(processIdentity: target.filterIdentity)
                async let totalCount = store.totalCount(matching: query)
                async let newestEvents = store.events(
                    matching: query,
                    sortOrder: .newestFirst,
                    limit: settings.maxEvents
                )
                let (total, newest) = try await (totalCount, newestEvents)
                let events = Array(newest.reversed())
                let context = MacFSWAnalysisProcessContext(
                    displayName: target.displayName,
                    processName: target.processName,
                    pid: target.pid,
                    executablePath: target.executablePath,
                    signingSummary: target.signingSummary,
                    uid: target.uid,
                    gid: target.gid,
                    eventCount: target.eventCount,
                    isPlatformBinary: target.isPlatformBinary,
                    lifecycle: target.lifecycle.title
                )
                let prepared = MacFSWAnalysisPayloadBuilder.build(
                    process: context,
                    events: events,
                    totalEventCount: total
                )
                await MainActor.run {
                    guard let self, self.analysisGeneration == generation else {
                        return
                    }
                    self.analysisStatusText = "Analyzing \(target.displayName)..."
                }

                let request = MacFSWLLMRequest(
                    settings: settings,
                    systemPrompt: prepared.systemPrompt,
                    userPrompt: prepared.userPrompt
                )
                let stream = try await client.streamAnalysis(request: request)
                var accumulated = ""

                for try await delta in stream {
                    try Task.checkCancellation()
                    accumulated += delta.text
                    await MainActor.run {
                        guard let self, self.analysisGeneration == generation else {
                            return
                        }
                        self.streamingAnalysisMarkdown = accumulated
                    }
                }

                let finalMarkdown = accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "No text was returned by the configured model."
                    : accumulated
                let result = MacFSWAnalysisResult(
                    processID: target.id,
                    processDisplayName: target.displayName,
                    createdAt: startedAt,
                    durationSeconds: Date().timeIntervalSince(startedAt),
                    scope: "Selected process, current session",
                    providerSummary: "\(settings.endpoint.rawValue) · \(settings.model)",
                    eventCount: prepared.eventCount,
                    payloadEventCount: prepared.payloadEventCount,
                    pathCount: prepared.pathCount,
                    operationCount: prepared.operationCount,
                    markdown: finalMarkdown
                )
                await MainActor.run {
                    guard let self, self.analysisGeneration == generation else {
                        return
                    }
                    self.analysisResults.insert(result, at: 0)
                    self.selectedAnalysisID = result.id
                    self.streamingAnalysisMarkdown = ""
                    self.isAnalysisRunning = false
                    self.analysisTask = nil
                    self.analysisStatusText = "Completed \(target.displayName)."
                }
            } catch {
                await MainActor.run {
                    guard let self, self.analysisGeneration == generation else {
                        return
                    }
                    if self.isCancellationError(error) {
                        self.analysisStatusText = self.streamingAnalysisMarkdown.isEmpty ? "Analysis cancelled." : "Analysis cancelled. Partial output is still visible."
                    } else {
                        self.analysisStatusText = self.userFacingMessage(error)
                        self.analysisRunError = Self.analysisError(from: error, settings: settings)
                        self.reportError(error)
                    }
                    self.isAnalysisRunning = false
                    self.analysisTask = nil
                }
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        if isAnalysisRunning {
            isAnalysisRunning = false
            analysisStatusText = streamingAnalysisMarkdown.isEmpty ? "Analysis cancelled." : "Analysis cancelled. Partial output is still visible."
        }
    }

    func clearAnalysisHistory() {
        analysisResults.removeAll(keepingCapacity: false)
        selectedAnalysisID = nil
    }

    func testLLMConnection() {
        guard !isTestingLLMConnection else {
            return
        }
        llmConnectionTestState = .testing
        var settings = llmSettings
        settings.streamResponses = false
        settings.maxEvents = 1
        let client = llmClient
        Task { [weak self] in
            do {
                let request = MacFSWLLMRequest(
                    settings: settings,
                    systemPrompt: "You are a connection test endpoint.",
                    userPrompt: "Reply with OK."
                )
                let stream = try await client.streamAnalysis(request: request)
                var receivedText = false
                for try await delta in stream {
                    if !delta.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        receivedText = true
                        break
                    }
                }
                await MainActor.run {
                    self?.llmConnectionTestState = receivedText
                        ? .succeeded("Connection OK")
                        : .failed(MacFSWConnectionTestError(
                            title: "No Text Returned",
                            message: "The provider accepted the request but did not return text output.",
                            diagnostic: "Endpoint: \(settings.endpoint.rawValue)\nModel: \(settings.model)\nBase URL: \(settings.baseURL)"
                        ))
                }
            } catch {
                await MainActor.run {
                    self?.llmConnectionTestState = .failed(Self.connectionTestError(from: error, settings: settings))
                }
            }
        }
    }

    private static func connectionTestError(
        from error: Error,
        settings: MacFSWLLMSettings
    ) -> MacFSWConnectionTestError {
        let endpointURL = MacFSWLLMClient.endpointURL(baseURL: settings.baseURL, endpoint: settings.endpoint)?
            .absoluteString ?? "\(settings.baseURL)\(settings.endpoint.rawValue)"
        if let clientError = error as? MacFSWLLMClientError,
           let details = clientError.httpDetails {
            return MacFSWConnectionTestError(
                title: details.title,
                message: details.message,
                diagnostic: [
                    "Endpoint: \(endpointURL)",
                    "Model: \(settings.model)",
                    "",
                    details.diagnosticText,
                ].joined(separator: "\n")
            )
        }
        if let clientError = error as? MacFSWLLMClientError,
           let body = clientError.streamErrorBody {
            let message = MacFSWLLMDeltaExtractor.errorMessages(from: body).first ?? clientError.localizedDescription
            return MacFSWConnectionTestError(
                title: "Provider Stream Error",
                message: message,
                diagnostic: [
                    "Endpoint: \(endpointURL)",
                    "Model: \(settings.model)",
                    "",
                    body,
                ].joined(separator: "\n")
            )
        }

        let message = (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
        return MacFSWConnectionTestError(
            title: "Connection Test Failed",
            message: message,
            diagnostic: [
                "Endpoint: \(endpointURL)",
                "Model: \(settings.model)",
                "",
                message,
            ].joined(separator: "\n")
        )
    }

    private static func analysisError(
        from error: Error,
        settings: MacFSWLLMSettings
    ) -> MacFSWConnectionTestError {
        var analysisError = connectionTestError(from: error, settings: settings)
        if analysisError.title == "Connection Test Failed" {
            analysisError.title = "Analysis Request Failed"
        }
        return analysisError
    }

    var captureSettingsLocked: Bool {
        captureState == .recording || captureState == .connecting || captureState == .stopping
    }

    func updateCaptureProfile(_ profile: MacFSWCaptureProfile) {
        updateCaptureConfig { config in
            config.profile = profile
            config.eventTypes = MacFSWCaptureConfig.defaultEventTypes(for: profile)
        }
    }

    func updateCaptureBatchSize(_ value: Int) {
        updateCaptureConfig { config in
            config.batchSize = max(1, value)
        }
    }

    func updateCaptureBatchInterval(_ value: Int) {
        updateCaptureConfig { config in
            config.batchIntervalMS = max(10, value)
        }
    }

    func updateCaptureDuration(_ value: Int) {
        updateCaptureConfig { config in
            config.maxCaptureDurationSeconds = max(5, value)
        }
    }

    func updateExcludedProcesses(_ text: String) {
        updateCaptureConfig { config in
            config.excludedProcessNames = Self.lines(from: text)
        }
    }

    func updateExcludePaths(_ text: String) {
        updateCaptureConfig { config in
            config.excludePaths = Self.lines(from: text)
        }
    }

    private func updateCaptureConfig(_ update: (inout MacFSWCaptureConfig) -> Void) {
        guard !captureSettingsLocked else {
            return
        }
        var updatedSession = session
        var config = updatedSession.captureConfig
        update(&config)
        updatedSession.captureConfig = config.transportSafe
        updatedSession.metadata.updatedAt = Date()
        session = updatedSession
    }

    private static func lines(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func selectAnalysis(_ result: MacFSWAnalysisResult) {
        selectedAnalysisID = result.id
        selectedPage = .analysis
    }

    private func refreshFilteredEvents(
        using queryOverride: MacFSWEventQuery?,
        allowAutoSelection: Bool = false
    ) async {
        let parsedQuery = queryOverride ?? MacFSWQueryParser.parse(queryText)
        let query = queryWithSelectedProcessFilter(parsedQuery)
        filterTask?.cancel()
        let generation = beginFilterRefresh()
        let store = eventStore
        let selectedEventIDAtStart = selectedEventID
        let followModeAtStart = followMode
        let requestedRangeAtStart = lastRequestedRowRange
        let pageSize = rowPageSize
        let oldSnapshot = activeSnapshot
        let task = Task { [weak self] in
            do {
                let snapshot = try await store.createResultSnapshot(matching: query, sortOrder: .oldestFirst)
                let operationSummaries = try await store.operationSummaries(matching: query)
                guard !Task.isCancelled else {
                    return
                }
                let count = snapshot.visibleCount

                let existingSelectionRow: Int?
                if let selectedEventIDAtStart {
                    existingSelectionRow = try await store.visibleRowIndex(
                        of: selectedEventIDAtStart,
                        in: snapshot
                    )
                } else {
                    existingSelectionRow = nil
                }
                guard !Task.isCancelled else {
                    return
                }

                let selectedRowForRefresh = existingSelectionRow ?? (allowAutoSelection && count > 0 ? count - 1 : nil)
                let initialRange: Range<Int>
                if count <= 0 {
                    initialRange = 0..<0
                } else if let selectedRowForRefresh {
                    let lower = max(0, min(selectedRowForRefresh, count - 1) - pageSize + 1)
                    let upper = min(count, lower + pageSize)
                    initialRange = lower..<upper
                } else if followModeAtStart == .live {
                    initialRange = max(0, count - pageSize)..<count
                } else if requestedRangeAtStart.lowerBound < requestedRangeAtStart.upperBound {
                    let lower = max(0, min(count - 1, requestedRangeAtStart.lowerBound))
                    let upper = min(count, max(lower + 1, min(count, requestedRangeAtStart.upperBound)))
                    initialRange = lower..<min(count, max(upper, min(count, lower + pageSize)))
                } else {
                    initialRange = 0..<min(count, pageSize)
                }

                let rows = try await store.rowSummaries(
                    in: snapshot,
                    visibleRange: initialRange
                )
                guard !Task.isCancelled else {
                    return
                }

                let selection: (id: UUID, row: Int)?
                if let existingSelectionRow, let selectedEventIDAtStart {
                    selection = (selectedEventIDAtStart, existingSelectionRow)
                } else if let selectedRowForRefresh {
                    let offset = selectedRowForRefresh - initialRange.lowerBound
                    if rows.indices.contains(offset) {
                        selection = (rows[offset].id, selectedRowForRefresh)
                    } else {
                        selection = nil
                    }
                } else {
                    selection = nil
                }

                let selectedEvent: MacFSWFileEvent?
                if let selection {
                    selectedEvent = try await store.event(id: selection.id)
                } else {
                    selectedEvent = nil
                }
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.commitFilterRefresh(
                        query: query,
                        snapshot: snapshot,
                        initialRange: initialRange,
                        rows: rows,
                        operationSummaries: operationSummaries,
                        selection: selection,
                        selectedEvent: selectedEvent
                    )
                    if let oldSnapshot, oldSnapshot.id != snapshot.id {
                        self.retireSnapshot(oldSnapshot)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.isApplyingFilter = false
                    self.selectedEventIsLoading = false
                    self.reportError(error)
                }
            }
        }
        filterTask = task
        await task.value
    }

    private func beginFilterRefresh() -> Int {
        queryGeneration += 1
        cancelSelectedEventLoad()
        cancelRowLoads()
        pendingVisibleMatchCount = 0
        pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
        isApplyingFilter = true
        selectedEventIsLoading = false
        return queryGeneration
    }

    private func commitFilterRefresh(
        query: MacFSWEventQuery,
        snapshot: MacFSWEventResultSnapshot,
        initialRange: Range<Int>,
        rows: [MacFSWEventRowSummary],
        operationSummaries: [MacFSWOperationEventSummary],
        selection: (id: UUID, row: Int)?,
        selectedEvent: MacFSWFileEvent?
    ) {
        filterTask = nil
        activeQuery = query
        activeSnapshot = snapshot
        totalMatchingEventCount = snapshot.totalCount
        self.visibleEventCount = snapshot.visibleCount
        self.operationSummaries = self.operationSummaries(from: operationSummaries)

        rowCache.removeAll(keepingCapacity: true)
        loadedRowPages.removeAll(keepingCapacity: true)
        inFlightRowPages.removeAll(keepingCapacity: true)
        rowPageAccessTicks.removeAll(keepingCapacity: true)
        lastRequestedRowRange = initialRange
        for (offset, row) in rows.enumerated() {
            rowCache[initialRange.lowerBound + offset] = row
        }
        rebuildLoadedPages(visibleCount: snapshot.visibleCount)
        evictRowPagesIfNeeded(visibleCount: snapshot.visibleCount)
        rowCacheVersion += 1
        rowCacheResetSerial += 1
        tableResetSerial += 1

        if selectedEventID != selection?.id {
            selectedEventID = selection?.id
            if selection == nil {
                selectionResetSerial += 1
            }
        }
        selectedRow = selection?.row
        self.selectedEvent = selectedEvent
        selectedEventIsLoading = false

        if followMode == .live {
            unseenEventCount = 0
            isViewingLiveEdge = true
        }
        isApplyingFilter = false
        lastUpdatedAt = Date()
        preloadRowsForCurrentViewport()
    }

    private func retireSnapshot(_ snapshot: MacFSWEventResultSnapshot) {
        retiredSnapshotIDs.insert(snapshot.id)
        scheduleSnapshotCleanup()
    }

    private func scheduleSnapshotCleanup() {
        snapshotCleanupTask?.cancel()
        snapshotCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            await self?.flushRetiredSnapshots()
        }
    }

    private func flushRetiredSnapshots() async {
        let snapshotIDs = Array(retiredSnapshotIDs)
        retiredSnapshotIDs.removeAll(keepingCapacity: true)
        snapshotCleanupTask = nil
        guard !snapshotIDs.isEmpty else {
            return
        }

        do {
            try await eventStore.deleteResultSnapshots(snapshotIDs)
        } catch {
            reportError(error)
        }
    }

    private func cancelSnapshotCleanup() {
        snapshotCleanupTask?.cancel()
        snapshotCleanupTask = nil
        retiredSnapshotIDs.removeAll(keepingCapacity: true)
    }

    private func processSummary(for id: MacFSWProcessSummary.ID) -> MacFSWProcessSummary? {
        processSummaryIndex[id] ?? processSummaries.first { $0.id == id }
    }

    private func queryWithSelectedProcessFilter(_ baseQuery: MacFSWEventQuery) -> MacFSWEventQuery {
        guard let selectedProcessID,
              let summary = processSummary(for: selectedProcessID) else {
            return baseQuery
        }

        var query = baseQuery
        query.processIdentity = summary.filterIdentity
        return query
    }

    func pauseLiveView() {
        guard followMode == .live else {
            return
        }
        followMode = .paused
    }

    func selectEvent(_ eventID: UUID?, row: Int? = nil) {
        selectedRow = row
        if row != nil || eventID != nil {
            pauseLiveView()
        }
        guard let eventID else {
            selectedEventID = nil
            if let row, row >= 0, row < visibleEventCount {
                selectedEventIsLoading = true
                requestRows(row..<min(row + 1, visibleEventCount))
                loadSelectedEvent(atVisibleRow: row, generation: queryGeneration)
            } else {
                cancelSelectedEventLoad()
                selectedEvent = nil
                selectedEventIsLoading = false
            }
            return
        }
        if selectedEventID == eventID, selectedEvent?.id == eventID {
            selectedEventIsLoading = false
            return
        }
        selectedEventID = eventID
        loadSelectedEvent(eventID, generation: queryGeneration)
    }

    func clearEventSelection() {
        cancelSelectedEventLoad()
        selectedEventID = nil
        selectedRow = nil
        selectedEvent = nil
        selectedEventIsLoading = false
        selectionResetSerial += 1
    }

    private func nextSelectedEventLoadGeneration() -> Int {
        selectedEventLoadTask?.cancel()
        selectedEventLoadTask = nil
        selectedEventLoadGeneration += 1
        return selectedEventLoadGeneration
    }

    private func cancelSelectedEventLoad() {
        selectedEventLoadTask?.cancel()
        selectedEventLoadTask = nil
        selectedEventLoadGeneration += 1
    }

    private func loadSelectedEvent(_ eventID: UUID, generation: Int) {
        let loadGeneration = nextSelectedEventLoadGeneration()
        selectedEventIsLoading = true
        let store = eventStore
        selectedEventLoadTask = Task { [weak self] in
            do {
                guard !Task.isCancelled else {
                    return
                }
                let event = try await store.event(id: eventID)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self,
                          self.queryGeneration == generation,
                          self.selectedEventLoadGeneration == loadGeneration,
                          self.selectedEventID == eventID else {
                        return
                    }
                    self.selectedEvent = event
                    self.selectedEventIsLoading = false
                    self.selectedEventLoadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self, self.selectedEventLoadGeneration == loadGeneration else {
                        return
                    }
                    self.selectedEventIsLoading = false
                    self.selectedEventLoadTask = nil
                    self.reportError(error)
                }
            }
        }
    }

    private func loadSelectedEvent(atVisibleRow row: Int, generation: Int) {
        let store = eventStore
        guard let snapshot = activeSnapshot else {
            cancelSelectedEventLoad()
            selectedEventIsLoading = false
            return
        }
        let loadGeneration = nextSelectedEventLoadGeneration()
        selectedEventLoadTask = Task { [weak self] in
            do {
                guard !Task.isCancelled else {
                    return
                }
                let event = try await store.event(
                    in: snapshot,
                    visibleRow: row
                )
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self,
                          self.queryGeneration == generation,
                          self.selectedEventLoadGeneration == loadGeneration,
                          self.selectedRow == row else {
                        return
                    }
                    self.selectedEvent = event
                    self.selectedEventID = event?.id
                    self.selectedEventIsLoading = false
                    self.selectedEventLoadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.queryGeneration == generation,
                          self.selectedEventLoadGeneration == loadGeneration,
                          self.selectedRow == row else {
                        return
                    }
                    self.selectedEventIsLoading = false
                    self.selectedEventLoadTask = nil
                    self.reportError(error)
                }
            }
        }
    }

    private func promoteSelectedRowIfLoaded(in range: Range<Int>) {
        guard let selectedRow, range.contains(selectedRow), let summary = rowCache[selectedRow] else {
            return
        }
        if selectedEventID != summary.id {
            selectedEventID = summary.id
            loadSelectedEvent(summary.id, generation: queryGeneration)
        }
    }

    func jumpToLive() {
        renderTask?.cancel()
        renderTask = nil
        let visibleMutationCount = pendingVisibleMatchCount
        let visibleRowSummaries = pendingVisibleRowSummaries
        pendingVisibleMatchCount = 0
        pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
        followMode = .live
        unseenEventCount = 0
        isViewingLiveEdge = true
        selectedEventID = nil
        selectedRow = nil
        selectedEvent = nil
        selectedEventIsLoading = false
        selectionResetSerial += 1
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.activeSnapshot == nil {
                await self.refreshFilteredEvents()
            } else if visibleMutationCount > 0 {
                await self.refreshVisibleRowsAfterStoreChange(
                    visibleMutationCount: visibleMutationCount,
                    appendedSummaries: visibleRowSummaries
                )
            } else {
                self.preloadRowsForCurrentViewport()
                self.lastUpdatedAt = Date()
            }
            self.scrollToLiveSerial += 1
        }
    }

    func setFrozen(_ isFrozen: Bool) {
        if isFrozen {
            followMode = .frozen
        } else {
            jumpToLive()
        }
    }

    func saveSession() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: MacFSWSessionArchive.nativeExtension)!]
        panel.nameFieldStringValue = "\(session.name).\(MacFSWSessionArchive.nativeExtension)"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                try await MacFSWSessionArchive.saveSession(session, from: eventStore, to: url)
            } catch {
                await MainActor.run {
                    reportError(error)
                }
            }
        }
    }

    func openSession() {
        stopCapture()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: MacFSWSessionArchive.nativeExtension)!]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                let openedStore = try MacFSWSessionArchive.openSessionStore(from: url)
                let opened = try await openedStore.sessionMetadata()
                let stats = try await openedStore.stats()
                let oldStore = await MainActor.run { () -> MacFSWSQLiteEventStore in
                    let oldStore = eventStore
                    eventStore = openedStore
                    session = opened
                    queryText = ""
                    captureStats = stats
                    resetVisibleStateForLoadedStore()
                    return oldStore
                }
                await cleanupStoreIfOwned(oldStore)
                await refreshProcessSummariesFromStore()
                await refreshFilteredEvents(allowAutoSelection: true)
            } catch {
                await MainActor.run {
                    reportError(error)
                }
            }
        }
    }

    private func ingest(_ batch: MacFSWEventBatch) async {
        do {
            let result = try await eventStore.appendReturningEvents(batch.events)
            updateProcessSummaries(with: result.events)
            var stats = batch.stats
            stats.deliveredEvents = result.stats.deliveredEvents
            pendingCaptureStats = stats
            let visibleEvents = result.events.filter { activeQuery.matches($0) }
            pendingVisibleMatchCount += visibleEvents.count
            pendingVisibleRowSummaries.append(contentsOf: visibleEvents.map(MacFSWEventRowSummary.init(event:)))

            if followMode != .live {
                unseenEventCount += visibleEvents.count
            }
            scheduleRenderRefresh()
        } catch {
            reportError(error)
        }
    }

    private func scheduleRenderRefresh(immediate: Bool = false) {
        if immediate {
            renderTask?.cancel()
            renderTask = nil
        }
        guard renderTask == nil else {
            return
        }

        renderTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.applyScheduledRender()
        }
    }

    private func applyScheduledRender() async {
        renderTask = nil
        if let pendingCaptureStats {
            captureStats = pendingCaptureStats
            self.pendingCaptureStats = nil
        }

        guard !isApplyingFilter else {
            pendingVisibleMatchCount = 0
            pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
            lastUpdatedAt = Date()
            return
        }

        guard followMode == .live else {
            lastUpdatedAt = Date()
            return
        }

        let visibleMutationCount = pendingVisibleMatchCount
        let visibleRowSummaries = pendingVisibleRowSummaries
        pendingVisibleMatchCount = 0
        pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
        guard visibleMutationCount > 0 else {
            lastUpdatedAt = Date()
            return
        }

        await refreshVisibleRowsAfterStoreChange(
            visibleMutationCount: visibleMutationCount,
            appendedSummaries: visibleRowSummaries
        )
    }

    private func refreshVisibleRowsAfterStoreChange(
        visibleMutationCount: Int,
        appendedSummaries: [MacFSWEventRowSummary]
    ) async {
        do {
            guard let snapshot = activeSnapshot else {
                await refreshFilteredEvents()
                return
            }
            let previousCount = visibleEventCount
            let previousTotal = totalMatchingEventCount
            let updatedSnapshot = try await eventStore.appendRowsToResultSnapshot(
                snapshot,
                rows: appendedSummaries,
                limit: activeQuery.limit
            )
            activeSnapshot = updatedSnapshot
            let total = updatedSnapshot.totalCount
            let count = updatedSnapshot.visibleCount
            applyOperationSummaryDelta(from: appendedSummaries)
            let previousWindowStart = max(0, previousTotal - previousCount)
            let windowStart = max(0, total - count)
            let windowShift = max(0, windowStart - previousWindowStart)
            let appendedVisibleCount = min(visibleMutationCount, count)
            var didPrepareChangedRows = false

            if windowShift > 0 {
                didPrepareChangedRows = slideRowWindowCache(
                    shiftedBy: windowShift,
                    appendedVisibleCount: appendedVisibleCount,
                    appendedSummaries: appendedSummaries,
                    visibleCount: count
                )
            } else if count > previousCount {
                didPrepareChangedRows = cacheAppendedRows(
                    appendedSummaries,
                    previousCount: previousCount,
                    newCount: count
                )
            }
            visibleEventCount = count
            totalMatchingEventCount = total
            if windowShift > 0 {
                if !didPrepareChangedRows {
                    resetRowCache(resetTable: false)
                }
            } else if activeQuery.hasVisibleLimit, visibleMutationCount > 0, count == activeQuery.limit, previousCount == count {
                resetRowCache(resetTable: false)
            } else if count < previousCount {
                resetRowCache(resetTable: true)
            } else if count > previousCount {
                if !didPrepareChangedRows {
                    invalidateRowPages(for: previousCount..<count)
                }
            }

            if let currentSelectedEventID = selectedEventID {
                if let row = try await eventStore.visibleRowIndex(
                    of: currentSelectedEventID,
                    in: updatedSnapshot
                ) {
                    selectedRow = row
                } else {
                    selectedEventID = nil
                    selectedRow = nil
                    selectedEvent = nil
                    selectedEventIsLoading = false
                    selectionResetSerial += 1
                }
            }

            if followMode == .live, isViewingLiveEdge {
                unseenEventCount = 0
            }
            preloadRowsForCurrentViewport()
            lastUpdatedAt = Date()
        } catch {
            reportError(error)
        }
    }

    func cachedRow(at row: Int) -> MacFSWEventRowSummary? {
        markRowPageAccess(row / rowPageSize)
        return rowCache[row]
    }

    func requestRows(_ range: Range<Int>) {
        guard visibleEventCount > 0 else {
            return
        }
        let lowerBound = max(0, min(visibleEventCount, range.lowerBound))
        let upperBound = max(lowerBound, min(visibleEventCount, range.upperBound))
        guard lowerBound < upperBound else {
            return
        }
        lastRequestedRowRange = lowerBound..<upperBound

        let expandedLower = max(0, lowerBound - 120)
        let expandedUpper = min(visibleEventCount, upperBound + 240)
        loadPages(for: expandedLower..<expandedUpper)
    }

    func liveEdgeChanged(_ isAtLiveEdge: Bool) {
        isViewingLiveEdge = isAtLiveEdge
        if isAtLiveEdge, followMode == .live {
            unseenEventCount = 0
        }
    }

    private func preloadRowsForCurrentViewport() {
        guard visibleEventCount > 0 else {
            return
        }
        if followMode == .live {
            let lower = max(0, visibleEventCount - 240)
            requestRows(lower..<visibleEventCount)
        } else {
            requestRows(0..<min(visibleEventCount, 240))
        }
    }

    private func resetRowCache(resetTable: Bool) {
        queryGeneration += 1
        cancelRowLoads()
        rowCache.removeAll(keepingCapacity: true)
        loadedRowPages.removeAll(keepingCapacity: true)
        inFlightRowPages.removeAll(keepingCapacity: true)
        rowPageAccessTicks.removeAll(keepingCapacity: true)
        lastRequestedRowRange = 0..<0
        pendingVisibleMatchCount = 0
        pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
        rowCacheVersion += 1
        rowCacheResetSerial += 1
        if resetTable {
            tableResetSerial += 1
        }
    }

    private func visibleCount(totalCount: Int, query: MacFSWEventQuery) -> Int {
        query.visibleCount(totalCount: totalCount)
    }

    private func cacheAppendedRows(
        _ summaries: [MacFSWEventRowSummary],
        previousCount: Int,
        newCount: Int
    ) -> Bool {
        let insertedCount = newCount - previousCount
        guard insertedCount > 0, !summaries.isEmpty else {
            return false
        }

        let cacheCount = min(insertedCount, summaries.count, maxDirectAppendCacheRows)
        let cacheStart = newCount - cacheCount
        let tailSummaries = summaries.suffix(cacheCount)
        for (offset, summary) in tailSummaries.enumerated() {
            rowCache[cacheStart + offset] = summary
        }

        markLoadedPagesIfComplete(overlapping: cacheStart..<newCount, visibleCount: newCount)
        evictRowPagesIfNeeded(visibleCount: newCount)
        rowCacheVersion += 1
        return true
    }

    private func slideRowWindowCache(
        shiftedBy shiftCount: Int,
        appendedVisibleCount: Int,
        appendedSummaries: [MacFSWEventRowSummary],
        visibleCount: Int
    ) -> Bool {
        let shiftCount = min(max(0, shiftCount), visibleCount)
        let appendedVisibleCount = min(max(0, appendedVisibleCount), visibleCount)
        guard shiftCount > 0, appendedVisibleCount > 0, appendedSummaries.count >= appendedVisibleCount else {
            return false
        }

        queryGeneration += 1
        cancelRowLoads()

        let appendedStart = visibleCount - appendedVisibleCount
        var shiftedCache: [Int: MacFSWEventRowSummary] = [:]
        shiftedCache.reserveCapacity(min(rowCache.count + appendedVisibleCount, visibleCount))

        for (row, summary) in rowCache {
            let shiftedRow = row - shiftCount
            if shiftedRow >= 0, shiftedRow < appendedStart {
                shiftedCache[shiftedRow] = summary
            }
        }

        for (offset, summary) in appendedSummaries.suffix(appendedVisibleCount).enumerated() {
            shiftedCache[appendedStart + offset] = summary
        }

        rowCache = shiftedCache
        loadedRowPages.removeAll(keepingCapacity: true)
        rowPageAccessTicks.removeAll(keepingCapacity: true)
        if lastRequestedRowRange.lowerBound < lastRequestedRowRange.upperBound {
            let shiftedLower = max(0, lastRequestedRowRange.lowerBound - shiftCount)
            let shiftedUpper = max(shiftedLower, min(visibleCount, lastRequestedRowRange.upperBound - shiftCount))
            lastRequestedRowRange = shiftedLower..<shiftedUpper
        }
        rebuildLoadedPages(visibleCount: visibleCount)
        evictRowPagesIfNeeded(visibleCount: visibleCount)
        rowCacheVersion += 1
        rowCacheResetSerial += 1
        return true
    }

    private func rebuildLoadedPages(visibleCount: Int) {
        let pages = Set(rowCache.keys.map { $0 / rowPageSize })
        for page in pages {
            let lowerBound = page * rowPageSize
            let upperBound = min(visibleCount, lowerBound + rowPageSize)
            guard lowerBound < upperBound else {
                continue
            }
            let isComplete = (lowerBound..<upperBound).allSatisfy { rowCache[$0] != nil }
            if isComplete {
                loadedRowPages.insert(page)
                markRowPageAccess(page)
            }
        }
    }

    private func markLoadedPagesIfComplete(overlapping range: Range<Int>, visibleCount: Int) {
        guard range.lowerBound < range.upperBound else {
            return
        }
        let firstPage = range.lowerBound / rowPageSize
        let lastPage = (range.upperBound - 1) / rowPageSize
        for page in firstPage...lastPage {
            let lowerBound = page * rowPageSize
            let upperBound = min(visibleCount, lowerBound + rowPageSize)
            guard lowerBound < upperBound else {
                continue
            }
            let isComplete = (lowerBound..<upperBound).allSatisfy { rowCache[$0] != nil }
            if isComplete {
                loadedRowPages.insert(page)
                markRowPageAccess(page)
            }
        }
    }

    private func invalidateRowPages(for range: Range<Int>) {
        guard range.lowerBound < range.upperBound else {
            return
        }
        let firstPage = range.lowerBound / rowPageSize
        let lastPage = (range.upperBound - 1) / rowPageSize
        for page in firstPage...lastPage {
            rowLoadTasks[page]?.cancel()
            rowLoadTasks[page] = nil
            inFlightRowPages.remove(page)
            loadedRowPages.remove(page)
            rowPageAccessTicks[page] = nil
            let lowerBound = page * rowPageSize
            let upperBound = min(visibleEventCount, lowerBound + rowPageSize)
            guard lowerBound < upperBound else {
                continue
            }
            for row in lowerBound..<upperBound {
                rowCache[row] = nil
            }
        }
        rowCacheVersion += 1
    }

    private func cancelRowLoads() {
        for task in rowLoadTasks.values {
            task.cancel()
        }
        rowLoadTasks.removeAll(keepingCapacity: true)
        inFlightRowPages.removeAll(keepingCapacity: true)
    }

    private func loadPages(for range: Range<Int>) {
        let firstPage = range.lowerBound / rowPageSize
        let lastPage = (range.upperBound - 1) / rowPageSize
        for page in firstPage...lastPage {
            markRowPageAccess(page)
            guard !loadedRowPages.contains(page), !inFlightRowPages.contains(page) else {
                continue
            }
            loadPage(page)
        }
    }

    private func loadPage(_ page: Int) {
        inFlightRowPages.insert(page)
        let lowerBound = page * rowPageSize
        let upperBound = min(visibleEventCount, lowerBound + rowPageSize)
        guard lowerBound < upperBound else {
            inFlightRowPages.remove(page)
            return
        }

        let range = lowerBound..<upperBound
        let store = eventStore
        guard let snapshot = activeSnapshot else {
            inFlightRowPages.remove(page)
            return
        }
        let generation = queryGeneration
        rowLoadTasks[page] = Task { [weak self] in
            do {
                let rows = try await store.rowSummaries(
                    in: snapshot,
                    visibleRange: range
                )
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.inFlightRowPages.remove(page)
                    self.rowLoadTasks[page] = nil
                    for (offset, row) in rows.enumerated() {
                        self.rowCache[range.lowerBound + offset] = row
                    }
                    self.loadedRowPages.insert(page)
                    self.markRowPageAccess(page)
                    self.promoteSelectedRowIfLoaded(in: range)
                    self.evictRowPagesIfNeeded()
                    self.rowCacheVersion += 1
                    self.lastUpdatedAt = Date()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.inFlightRowPages.remove(page)
                    self.rowLoadTasks[page] = nil
                    self.reportError(error)
                }
            }
        }
    }

    private func markRowPageAccess(_ page: Int) {
        rowPageAccessTick += 1
        rowPageAccessTicks[page] = rowPageAccessTick
    }

    private func evictRowPagesIfNeeded(visibleCount: Int? = nil) {
        guard loadedRowPages.count > maxCachedRowPages else {
            return
        }

        let visibleCount = visibleCount ?? self.visibleEventCount
        let protectedPages = protectedRowPages(visibleCount: visibleCount)
        let candidates = loadedRowPages
            .filter { !protectedPages.contains($0) }
            .sorted { (rowPageAccessTicks[$0] ?? 0) < (rowPageAccessTicks[$1] ?? 0) }
        let excess = loadedRowPages.count - maxCachedRowPages
        for page in candidates.prefix(excess) {
            loadedRowPages.remove(page)
            rowPageAccessTicks[page] = nil
            let lowerBound = page * rowPageSize
            let upperBound = min(visibleCount, lowerBound + rowPageSize)
            guard lowerBound < upperBound else {
                continue
            }
            for row in lowerBound..<upperBound {
                rowCache[row] = nil
            }
        }
    }

    private func protectedRowPages(visibleCount: Int? = nil) -> Set<Int> {
        let visibleCount = visibleCount ?? self.visibleEventCount
        var protected: Set<Int> = []
        func insertPages(for range: Range<Int>) {
            guard range.lowerBound < range.upperBound else {
                return
            }
            let lowerPage = max(0, range.lowerBound / rowPageSize)
            let upperPage = max(lowerPage, (range.upperBound - 1) / rowPageSize)
            for page in max(0, lowerPage - 1)...(upperPage + 1) {
                protected.insert(page)
            }
        }
        insertPages(for: lastRequestedRowRange)
        if followMode == .live, visibleCount > 0 {
            insertPages(for: max(0, visibleCount - rowPageSize)..<visibleCount)
        }
        return protected
    }

    private func captureDidFinish(_ error: Error?) {
        captureHandle = nil
        if let error {
            guard !isCancellationError(error) else {
                if captureState == .recording || captureState == .stopping {
                    captureState = .stopped
                }
                followMode = .paused
                unseenEventCount = 0
                isViewingLiveEdge = true
                return
            }
            captureState = .failed
            handleCaptureStartFailure(error)
        } else if captureState == .recording || captureState == .stopping {
            captureState = .stopped
        }
        if captureState != .recording {
            followMode = .paused
            unseenEventCount = 0
            isViewingLiveEdge = true
        }
    }

    private func handleCaptureStartFailure(_ error: Error) {
        guard !isCancellationError(error) else {
            captureState = .idle
            return
        }
        let message = userFacingMessage(error)
        errorMessage = message

        if isXPCConnectionFailure(error) {
            extensionInstaller.resetSubmission()
            extensionInstallState = .notReady
            extensionInstallMessage = "The installed Endpoint Extension is not accepting capture streams. It may be out of date; enable the System Extension again to install the bundled version."
            captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAvailable: true,
                endpointSecurityAuthorized: false,
                message: message
            )
        }
        if isFullDiskAccessError(message) {
            extensionInstallState = .failed
            extensionInstallMessage = message
            captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAvailable: true,
                endpointSecurityAuthorized: false,
                fullDiskAccessHint: true,
                message: message
            )
        }
    }

    private func isFullDiskAccessError(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("Full Disk Access")
            || message.localizedCaseInsensitiveContains("ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED")
    }

    private func isXPCConnectionFailure(_ error: Error) -> Bool {
        if let clientError = error as? MacFSWClientError {
            if case .xpcUnavailable = clientError {
                return true
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSXPCConnectionInvalid {
            return true
        }

        return nsError.localizedDescription.localizedCaseInsensitiveContains("XPC")
            || nsError.localizedDescription.localizedCaseInsensitiveContains("connection to service")
    }

    private func reportError(_ error: Error) {
        guard !isCancellationError(error) else {
            return
        }
        errorMessage = userFacingMessage(error)
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func userFacingMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: MacFSWAppModel

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

struct SidebarView: View {
    @EnvironmentObject private var model: MacFSWAppModel

    var body: some View {
        VStack(spacing: 0) {
            SidebarPageSwitcher()
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()

            ProcessFilterPane()
                .frame(maxHeight: .infinity)

            Divider()

            OperationStatsPane()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                SidebarSectionHeader("System Extension")
                SystemExtensionStatusView()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

struct SidebarPageSwitcher: View {
    @EnvironmentObject private var model: MacFSWAppModel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MacFSWNavigationPage.allCases) { page in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.selectedPage = page
                    }
                } label: {
                    SidebarPageSwitcherItem(
                        page: page,
                        isSelected: model.selectedPage == page
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(height: 34)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SidebarPageSwitcherItem: View {
    let page: MacFSWNavigationPage
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: page.symbolName)
                .font(.system(size: 12, weight: .medium))
            Text(page.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            if page.isBeta {
                MacFSWBetaBadge()
            }
        }
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(.easeInOut(duration: 0.14), value: isSelected)
    }

    private var background: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            return Color.primary.opacity(0.07)
        }
        return .clear
    }
}

struct SidebarSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct MacFSWBetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.10), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.orange.opacity(0.24), lineWidth: 1)
            }
            .accessibilityLabel("Beta feature")
    }
}

struct ProcessFilterPane: View {
    @EnvironmentObject private var model: MacFSWAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    SidebarSectionHeader("Processes")
                    Spacer()
                    Text("\(model.filteredProcessSummaries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(processActionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            TextField("Filter process or signing", text: $model.processSearchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)

            Toggle(isOn: $model.includeExitedProcesses) {
                HStack(spacing: 6) {
                    Text("Include Exited")
                    if model.filteredExitedProcessCount > 0 {
                        Text("\(model.filteredExitedProcessCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .padding(.horizontal, 12)

            if model.selectedPage == .monitor, model.selectedProcessID != nil {
                Button {
                    model.clearProcessFilter()
                } label: {
                    Label("Clear Process Filter", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
            }

            if model.filteredProcessGroups.isEmpty {
                Text("No process events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.filteredProcessGroups) { group in
                            if group.instanceCount > 1 {
                                Button {
                                    model.toggleProcessGroup(group.id)
                                } label: {
                                    ProcessGroupRow(
                                        group: group,
                                        isExpanded: model.expandedProcessGroupIDs.contains(group.id)
                                    )
                                }
                                .buttonStyle(.plain)

                                if model.expandedProcessGroupIDs.contains(group.id) {
                                    ForEach(group.summaries) { summary in
                                        Button {
                                            model.selectSidebarProcess(summary)
                                        } label: {
                                            ProcessSummaryRow(
                                                summary: summary,
                                                isSelected: isSelected(summary)
                                            )
                                            .padding(.leading, 14)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } else if let summary = group.summaries.first {
                                Button {
                                    model.selectSidebarProcess(summary)
                                } label: {
                                    ProcessSummaryRow(summary: summary, isSelected: isSelected(summary))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var processActionHint: String {
        switch model.selectedPage {
        case .monitor:
            "Click to filter events"
        case .analysis:
            "Click to select target"
        }
    }

    private func isSelected(_ summary: MacFSWProcessSummary) -> Bool {
        switch model.selectedPage {
        case .monitor:
            model.selectedProcessID == summary.id
        case .analysis:
            model.selectedAnalysisProcessID == summary.id
        }
    }
}

struct ProcessGroupRow: View {
    let group: MacFSWProcessGroupSummary
    let isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Image(systemName: group.processIconSymbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.processName)
                    .lineLimit(1)
                Text(groupSubtitle)
                    .font(.caption)
                    .foregroundStyle(group.exitedCount > 0 ? .orange : .secondary)
            }
            Spacer()
            Text("\(group.eventCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(.easeInOut(duration: 0.14), value: isExpanded)
    }

    private var groupSubtitle: String {
        if group.exitedCount > 0 {
            return "\(group.instanceCount) processes, \(group.exitedCount) exited"
        }
        return "\(group.instanceCount) processes"
    }
}

struct SidebarNavigationRow: View {
    let page: MacFSWNavigationPage
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: page.symbolName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 20)
            Text(page.title)
                .font(.system(size: 15, weight: .medium))
            Spacer(minLength: 0)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34)
            .padding(.horizontal, 10)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.14), value: isHovering)
            .animation(.easeInOut(duration: 0.14), value: isSelected)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}

struct CaptureSidebarStatusView: View {
    @EnvironmentObject private var model: MacFSWAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RecordingIndicatorView(isRecording: model.captureState == .recording)
                Text(model.statusText)
                    .font(.callout.weight(.medium))
                Spacer()
                if model.captureState == .recording {
                    Label(model.followMode.title, systemImage: model.followMode.symbolName)
                        .font(.caption)
                        .foregroundStyle(model.followMode == .live ? .green : .secondary)
                }
            }

            Text(model.captureStatusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}

struct OperationStatsPane: View {
    @EnvironmentObject private var model: MacFSWAppModel

    private let buckets: [MacFSWOperationBucket] = [
        .read,
        .create,
        .write,
        .rename,
        .delete,
        .metadata,
        .link,
    ]

    private var summaryByBucket: [MacFSWOperationBucket: MacFSWOperationSummary] {
        Dictionary(uniqueKeysWithValues: model.operationSummaries.map { ($0.bucket, $0) })
    }

    private var rankedSummaries: [MacFSWOperationSummary] {
        buckets.map { bucket in
            summaryByBucket[bucket] ?? MacFSWOperationSummary(bucket: bucket, eventCount: 0)
        }
        .sorted { lhs, rhs in
            if lhs.eventCount != rhs.eventCount {
                return lhs.eventCount > rhs.eventCount
            }
            return bucketRank(lhs.bucket) < bucketRank(rhs.bucket)
        }
    }

    private var total: Int {
        rankedSummaries.reduce(0) { $0 + $1.eventCount }
    }

    private var animationSignature: String {
        rankedSummaries
            .map { "\($0.id):\($0.eventCount)" }
            .joined(separator: "|")
    }

    private func bucketRank(_ bucket: MacFSWOperationBucket) -> Int {
        buckets.firstIndex(of: bucket) ?? buckets.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SidebarSectionHeader("Operations")
                Spacer()
                Text("\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(rankedSummaries) { summary in
                    OperationStatRow(summary: summary, total: total)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: animationSignature)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 220, alignment: .top)
    }
}

struct OperationStatRow: View {
    let summary: MacFSWOperationSummary
    let total: Int

    private var ratio: Double {
        guard total > 0 else {
            return 0
        }
        return min(1, max(0, Double(summary.eventCount) / Double(total)))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: summary.bucket.symbolName)
                    .font(.caption)
                    .foregroundStyle(summary.bucket.color)
                    .frame(width: 16)
                Text(summary.bucket.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(summary.eventCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(summary.bucket.color.opacity(0.72))
                        .frame(width: ratio > 0 ? max(2, proxy.size.width * ratio) : 0)
                        .animation(.easeInOut(duration: 0.22), value: ratio)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProcessSummaryRow: View {
    let summary: MacFSWProcessSummary
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: summary.processIconSymbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayName)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: summary.lifecycle.symbolName)
                        .foregroundStyle(lifecycleColor)
                    if summary.identityCount > 1 {
                        Text("PID reused")
                            .foregroundStyle(.orange)
                    }
                    Text(summary.signingSummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.caption)
            }
            Spacer()
            Text("\(summary.eventCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(.easeInOut(duration: 0.14), value: isSelected)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }

    private var lifecycleColor: Color {
        switch summary.lifecycle {
        case .running:
            return .green
        case .exited:
            return .secondary
        case .unknown:
            return .orange
        }
    }
}

struct MonitorView: View {
    @EnvironmentObject private var model: MacFSWAppModel

    var body: some View {
        VStack(spacing: 0) {
            MonitorCommandBar()
            EventTableView(
                rowCount: model.visibleEventCount,
                cacheVersion: model.rowCacheVersion,
                cacheResetSerial: model.rowCacheResetSerial,
                resetSerial: model.tableResetSerial,
                selectedEventID: $model.selectedEventID,
                selectedRow: model.selectedRow,
                followMode: model.followMode,
                scrollToLiveSerial: model.scrollToLiveSerial,
                selectionResetSerial: model.selectionResetSerial,
                rowProvider: { row in
                    model.cachedRow(at: row)
                },
                requestRows: { range in
                    model.requestRows(range)
                },
                onUserSelected: { row, eventID in
                    model.selectEvent(eventID, row: row)
                },
                onClearSelection: {
                    model.clearEventSelection()
                },
                onLiveEdgeChanged: { isAtLiveEdge in
                    model.liveEdgeChanged(isAtLiveEdge)
                }
            )
            StatusBar()
        }
    }
}

struct MonitorCommandBar: View {
    @EnvironmentObject private var model: MacFSWAppModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("(op:rename OR op:unlink) path:/Library NOT platform:true", text: $model.queryText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        Task { await model.refreshFilteredEvents() }
                    }
                    .onChange(of: model.queryText) {
                        model.scheduleQueryRefresh()
                    }

                if model.isApplyingFilter {
                    ProgressView()
                        .controlSize(.small)
                } else if !model.queryText.isEmpty {
                    Button {
                        model.queryText = ""
                        Task { await model.refreshFilteredEvents() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 7))

            Button {
                model.recordButtonTapped()
            } label: {
                Label(recordButtonTitle, systemImage: recordButtonSymbol)
            }

            if model.shouldShowJumpToLive {
                Button {
                    model.jumpToLive()
                } label: {
                    Label(model.jumpToLiveTitle, systemImage: "arrow.down.to.line")
                }
            }

            Button {
                model.clearView()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(model.visibleEventCount == 0 && model.captureStats.deliveredEvents == 0)

        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.background)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var recordButtonTitle: String {
        if model.captureState == .recording {
            return "Stop"
        }
        if model.captureHealth.fullDiskAccessHint {
            return "Open Full Disk Access"
        }
        return model.extensionInstallState == .ready ? "Record" : "Enable Extension"
    }

    private var recordButtonSymbol: String {
        if model.captureState == .recording {
            return "stop.circle.fill"
        }
        if model.captureHealth.fullDiskAccessHint {
            return "lock.shield"
        }
        return model.extensionInstallState == .ready ? "record.circle" : "puzzlepiece.extension"
    }
}

struct AnalysisResultsView: View {
    @EnvironmentObject private var model: MacFSWAppModel

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
    @EnvironmentObject private var model: MacFSWAppModel

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
                Label(process.displayName, systemImage: process.processIconSymbolName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
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
    @EnvironmentObject private var model: MacFSWAppModel

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
    @EnvironmentObject private var model: MacFSWAppModel

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

private enum MacFSWHelpWindow {
    static let userManualID = "macfsw-user-manual"
    private static let bundledManualName = "MacFSW-User-Manual"

    static func loadUserManualSections() -> [MacFSWUserManualSection] {
        parseUserManualSections(from: loadUserManualMarkdown())
    }

    static func loadUserManualMarkdown() -> String {
        let candidateURLs = [
            Bundle.main.url(forResource: bundledManualName, withExtension: "md"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("docs/user-manual.md"),
        ]

        for url in candidateURLs.compactMap({ $0 }) {
            if let markdown = try? String(contentsOf: url, encoding: .utf8), !markdown.isEmpty {
                return markdown
            }
        }

        return """
        # MacFSW User Manual

        The bundled user manual could not be loaded. Reinstall MacFSW or open `docs/user-manual.md` from the project workspace.
        """
    }

    private static func parseUserManualSections(from markdown: String) -> [MacFSWUserManualSection] {
        let lines = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var sections: [MacFSWUserManualSection] = []
        var currentTitle = "Overview"
        var currentLines: [String] = []
        var sectionIndex = 0

        func appendCurrentSection() {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                return
            }
            sections.append(
                MacFSWUserManualSection(
                    id: "manual-section-\(sectionIndex)",
                    title: currentTitle,
                    markdown: content
                )
            )
            sectionIndex += 1
        }

        for line in lines {
            if line.hasPrefix("## ") {
                appendCurrentSection()
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }

        appendCurrentSection()

        if sections.isEmpty {
            return [
                MacFSWUserManualSection(
                    id: "manual-section-empty",
                    title: "User Manual",
                    markdown: markdown
                )
            ]
        }
        return sections
    }
}

struct MacFSWUserManualSection: Identifiable, Hashable {
    var id: String
    var title: String
    var markdown: String
}

struct UserManualView: View {
    private let sections: [MacFSWUserManualSection]
    @State private var selectedSectionID: String

    init() {
        let loadedSections = MacFSWHelpWindow.loadUserManualSections()
        self.sections = loadedSections
        _selectedSectionID = State(initialValue: loadedSections.first?.id ?? "")
    }

    var body: some View {
        HStack(spacing: 0) {
            UserManualContentsView(
                sections: sections,
                selectedSectionID: $selectedSectionID
            )
            .frame(width: 250)

            Divider()

            UserManualSectionView(section: selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var selectedSection: MacFSWUserManualSection {
        sections.first { $0.id == selectedSectionID }
            ?? sections.first
            ?? MacFSWUserManualSection(
                id: "manual-section-empty",
                title: "User Manual",
                markdown: "# MacFSW User Manual\n\nNo manual content is available."
            )
    }
}

struct UserManualContentsView: View {
    let sections: [MacFSWUserManualSection]
    @Binding var selectedSectionID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Contents")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(sections) { section in
                        Button {
                            selectedSectionID = section.id
                        } label: {
                            UserManualContentsRow(
                                title: section.title,
                                isSelected: selectedSectionID == section.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(.bar)
    }
}

struct UserManualContentsRow: View {
    let title: String
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        Text(title)
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var background: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}

struct UserManualSectionView: View {
    let section: MacFSWUserManualSection

    var body: some View {
        ScrollView {
            MarkdownView(section.markdown)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .id(section.id)
        .background(Color(nsColor: .windowBackgroundColor))
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

enum MacFSWSettingsSection: String, CaseIterable, Identifiable {
    case general
    case analysis
    case capture
    case systemExtension

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
        }
    }

    var isBeta: Bool {
        switch self {
        case .analysis:
            true
        case .general, .capture, .systemExtension:
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct GeneralSettingsPane: View {
    @EnvironmentObject private var model: MacFSWAppModel

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

struct AnalysisSettingsPane: View {
    @EnvironmentObject private var model: MacFSWAppModel

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

struct CaptureSettingsPane: View {
    @EnvironmentObject private var model: MacFSWAppModel

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

struct SystemExtensionSettingsPane: View {
    @EnvironmentObject private var model: MacFSWAppModel

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

private extension MacFSWCaptureProfile {
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

struct RecordingIndicatorView: View {
    let isRecording: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            let opacity = isRecording ? 0.55 + 0.45 * sin(phase * .pi) : 1
            let scale = isRecording ? 0.92 + 0.12 * sin(phase * .pi) : 1

            Image(systemName: isRecording ? "record.circle.fill" : "circle")
                .foregroundStyle(isRecording ? .red : .secondary)
                .scaleEffect(scale)
                .opacity(opacity)
                .frame(width: 18, height: 18)
        }
    }
}

struct SystemExtensionStatusView: View {
    @EnvironmentObject private var model: MacFSWAppModel

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

struct StatusBar: View {
    @EnvironmentObject private var model: MacFSWAppModel

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

struct InspectorView: View {
    let event: MacFSWFileEvent?
    let isLoading: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let event {
                    Label {
                        Text(event.eventType.rawValue.uppercased())
                            .font(.title3.weight(.semibold))
                    } icon: {
                        Image(systemName: symbol(for: event.eventType))
                            .foregroundStyle(color(for: event.eventType))
                    }

                    SectionView("Path") {
                        DetailRow("Target", event.targetPath)
                    }

                    if event.sourcePath != nil || !event.parameters.isEmpty {
                        SectionView("Operation Details") {
                            if let sourcePath = event.sourcePath {
                                DetailRow("Source", sourcePath)
                            }
                            ForEach(event.parameters) { parameter in
                                DetailRow(parameter.label, parameter.value)
                            }
                        }
                    }

                    SectionView("Process") {
                        DetailRow("Name", event.process.processName)
                        DetailRow("PID", "\(event.process.pid)")
                        DetailRow("Executable", event.process.executablePath)
                        DetailRow("Signing ID", event.process.signingID ?? "-")
                        DetailRow("Team ID", event.process.teamID ?? "-")
                        DetailRow("Platform Binary", event.process.isPlatformBinary ? "Yes" : "No")
                    }

                    SectionView("Identity") {
                        DetailRow("UID/GID", "\(event.uid)/\(event.gid)")
                        DetailRow("Audit Token", event.process.auditToken)
                        DetailRow("CDHash", event.process.cdhash ?? "-")
                    }

                    SectionView("Raw Event") {
                        DetailRow("Event ID", event.id.uuidString)
                        DetailRow("Sequence", "\(event.sequence)")
                        DetailRow("Timestamp", "\(event.timestampNS)")
                        DetailRow("Raw Type", event.rawEventType)
                        DetailRow("ES Event Raw Value", event.rawEventTypeValue.map { String($0) } ?? "-")
                        DetailRow("ES Version", "\(event.rawEventVersion)")
                        DetailRow("Flags", "\(event.flags)")
                    }
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading Event")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ContentUnavailableView("No Event Selected", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SectionView<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(5)
        }
    }
}

private func format(timestampNS: UInt64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampNS) / 1_000_000_000)
    return date.formatted(date: .omitted, time: .standard)
}

private func symbol(for type: MacFSWEventType) -> String {
    switch type {
    case .create: "doc.badge.plus"
    case .open: "doc.text.magnifyingglass"
    case .close: "xmark.circle"
    case .write: "square.and.pencil"
    case .rename: "text.cursor"
    case .unlink: "trash"
    case .link: "link"
    case .clone: "plus.square.on.square"
    case .copyfile: "doc.on.doc"
    case .truncate: "scissors"
    case .exchangedata: "arrow.left.arrow.right"
    case .chmod, .chown, .setflags, .setacl: "person.badge.key"
    case .setextattr, .deleteextattr, .utimes: "tag"
    case .unknown: "questionmark.circle"
    }
}

private func color(for type: MacFSWEventType) -> Color {
    switch type.operationClass {
    case .read:
        .secondary
    case .write:
        .green
    case .metadata:
        .purple
    case .delete:
        .red
    case .link:
        .orange
    case .unknown:
        .secondary
    }
}
