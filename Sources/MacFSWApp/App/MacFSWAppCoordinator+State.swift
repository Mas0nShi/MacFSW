import AppKit
import Combine
import Darwin
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import UniformTypeIdentifiers

extension MacFSWAppCoordinator {
    var session: MacFSWResearchSession {
        get { sessionStore.session }
        set { sessionStore.session = newValue }
    }

    var eventStore: MacFSWSQLiteEventStore {
        get { sessionStore.eventStore }
        set { sessionStore.eventStore = newValue }
    }

    var visibleEventCount: Int {
        get { monitorStore.visibleEventCount }
        set { monitorStore.visibleEventCount = newValue }
    }

    var rowCacheVersion: Int {
        get { monitorStore.rowCacheVersion }
        set { monitorStore.rowCacheVersion = newValue }
    }

    var rowCacheResetSerial: Int {
        get { monitorStore.rowCacheResetSerial }
        set { monitorStore.rowCacheResetSerial = newValue }
    }

    var tableResetSerial: Int {
        get { monitorStore.tableResetSerial }
        set { monitorStore.tableResetSerial = newValue }
    }

    var selectedEventID: UUID? {
        get { monitorStore.selectedEventID }
        set { monitorStore.selectedEventID = newValue }
    }

    var selectedRow: Int? {
        get { monitorStore.selectedRow }
        set { monitorStore.selectedRow = newValue }
    }

    var selectedEvent: MacFSWFileEvent? {
        get { monitorStore.selectedEvent }
        set { monitorStore.selectedEvent = newValue }
    }

    var selectedEventIsLoading: Bool {
        get { monitorStore.selectedEventIsLoading }
        set { monitorStore.selectedEventIsLoading = newValue }
    }

    var queryText: String {
        get { monitorStore.queryText }
        set { monitorStore.queryText = newValue }
    }

    var followMode: MacFSWFollowMode {
        get { monitorStore.followMode }
        set { monitorStore.followMode = newValue }
    }

    var unseenEventCount: Int {
        get { monitorStore.unseenEventCount }
        set { monitorStore.unseenEventCount = newValue }
    }

    var isViewingLiveEdge: Bool {
        get { monitorStore.isViewingLiveEdge }
        set { monitorStore.isViewingLiveEdge = newValue }
    }

    var scrollToLiveSerial: Int {
        get { monitorStore.scrollToLiveSerial }
        set { monitorStore.scrollToLiveSerial = newValue }
    }

    var selectionResetSerial: Int {
        get { monitorStore.selectionResetSerial }
        set { monitorStore.selectionResetSerial = newValue }
    }

    var lastUpdatedAt: Date? {
        get { monitorStore.lastUpdatedAt }
        set { monitorStore.lastUpdatedAt = newValue }
    }

    var operationSummaries: [MacFSWOperationSummary] {
        get { monitorStore.operationSummaries }
        set { monitorStore.operationSummaries = newValue }
    }

    var selectedProcessID: MacFSWProcessSummary.ID? {
        get { monitorStore.selectedProcessID }
        set { monitorStore.selectedProcessID = newValue }
    }

    var isApplyingFilter: Bool {
        get { monitorStore.isApplyingFilter }
        set { monitorStore.isApplyingFilter = newValue }
    }

    var querySuggestions: [QuerySuggestion] {
        get { monitorStore.querySuggestions }
        set { monitorStore.querySuggestions = newValue }
    }

    var querySuggestionHighlight: Int? {
        get { monitorStore.querySuggestionHighlight }
        set { monitorStore.querySuggestionHighlight = newValue }
    }

    var isQuerySuggestionListVisible: Bool {
        get { monitorStore.isQuerySuggestionListVisible }
        set { monitorStore.isQuerySuggestionListVisible = newValue }
    }

    var queryDiagnostics: [MacFSWQueryDiagnostic] {
        get { monitorStore.queryDiagnostics }
        set { monitorStore.queryDiagnostics = newValue }
    }

    var queryFillCommitSerial: Int {
        monitorStore.queryFillCommitSerial
    }

    var queryFillCommitBasis: String {
        monitorStore.queryFillCommitBasis
    }

    var refreshTask: Task<Void, Never>? {
        get { monitorStore.refreshTask }
        set { monitorStore.refreshTask = newValue }
    }

    var renderTask: Task<Void, Never>? {
        get { monitorStore.renderTask }
        set { monitorStore.renderTask = newValue }
    }

    var filterTask: Task<Void, Never>? {
        get { monitorStore.filterTask }
        set { monitorStore.filterTask = newValue }
    }

    var operationSummaryTask: Task<Void, Never>? {
        get { monitorStore.operationSummaryTask }
        set { monitorStore.operationSummaryTask = newValue }
    }

    var selectedEventLoadTask: Task<Void, Never>? {
        get { monitorStore.selectedEventLoadTask }
        set { monitorStore.selectedEventLoadTask = newValue }
    }

    var selectedEventLoadGeneration: Int {
        get { monitorStore.selectedEventLoadGeneration }
        set { monitorStore.selectedEventLoadGeneration = newValue }
    }

    var snapshotCleanupTask: Task<Void, Never>? {
        get { monitorStore.snapshotCleanupTask }
        set { monitorStore.snapshotCleanupTask = newValue }
    }

    var retiredSnapshotIDs: Set<String> {
        get { monitorStore.retiredSnapshotIDs }
        set { monitorStore.retiredSnapshotIDs = newValue }
    }

    var activeQuery: MacFSWEventQuery {
        get { monitorStore.activeQuery }
        set { monitorStore.activeQuery = newValue }
    }

    var activeSnapshot: MacFSWEventResultSnapshot? {
        get { monitorStore.activeSnapshot }
        set { monitorStore.activeSnapshot = newValue }
    }

    var rowPageSize: Int { monitorStore.rowPageSize }
    var maxCachedRowPages: Int { monitorStore.maxCachedRowPages }
    var maxDirectAppendCacheRows: Int { monitorStore.maxDirectAppendCacheRows }

    var rowCache: [Int: MacFSWEventRowSummary] {
        get { monitorStore.rowCache }
        set { monitorStore.rowCache = newValue }
    }

    var loadedRowPages: Set<Int> {
        get { monitorStore.loadedRowPages }
        set { monitorStore.loadedRowPages = newValue }
    }

    var inFlightRowPages: Set<Int> {
        get { monitorStore.inFlightRowPages }
        set { monitorStore.inFlightRowPages = newValue }
    }

    var rowLoadTasks: [Int: Task<Void, Never>] {
        get { monitorStore.rowLoadTasks }
        set { monitorStore.rowLoadTasks = newValue }
    }

    var rowPageAccessTicks: [Int: Int] {
        get { monitorStore.rowPageAccessTicks }
        set { monitorStore.rowPageAccessTicks = newValue }
    }

    var rowPageAccessTick: Int {
        get { monitorStore.rowPageAccessTick }
        set { monitorStore.rowPageAccessTick = newValue }
    }

    var lastRequestedRowRange: Range<Int> {
        get { monitorStore.lastRequestedRowRange }
        set { monitorStore.lastRequestedRowRange = newValue }
    }

    var totalMatchingEventCount: Int {
        get { monitorStore.totalMatchingEventCount }
        set { monitorStore.totalMatchingEventCount = newValue }
    }

    var pendingVisibleMatchCount: Int {
        get { monitorStore.pendingVisibleMatchCount }
        set { monitorStore.pendingVisibleMatchCount = newValue }
    }

    var pendingVisibleRowSummaries: [MacFSWEventRowSummary] {
        get { monitorStore.pendingVisibleRowSummaries }
        set { monitorStore.pendingVisibleRowSummaries = newValue }
    }

    var queryGeneration: Int {
        get { monitorStore.queryGeneration }
        set { monitorStore.queryGeneration = newValue }
    }

    var liveRenderGeneration: Int {
        get { monitorStore.liveRenderGeneration }
        set { monitorStore.liveRenderGeneration = newValue }
    }

    var captureState: MacFSWCaptureState {
        get { captureStore.state }
        set { captureStore.state = newValue }
    }

    var captureHealth: MacFSWCaptureHealth {
        get { captureStore.health }
        set { captureStore.health = newValue }
    }

    var captureStats: MacFSWCaptureStats {
        get { captureStore.stats }
        set { captureStore.stats = newValue }
    }

    var processSearchText: String {
        get { processSidebarStore.processSearchText }
        set { processSidebarStore.processSearchText = newValue }
    }

    var processSummaries: [MacFSWProcessSummary] {
        processSidebarStore.processSummaries
    }

    var filteredProcessSummaries: [MacFSWProcessSummary] {
        processSidebarStore.filteredProcessSummaries
    }

    var filteredProcessGroups: [MacFSWProcessGroupSummary] {
        processSidebarStore.filteredProcessGroups
    }

    var expandedProcessGroupIDs: Set<String> {
        get { processSidebarStore.expandedProcessGroupIDs }
        set { processSidebarStore.expandedProcessGroupIDs = newValue }
    }

    var includeExitedProcesses: Bool {
        get { processSidebarStore.includeExitedProcesses }
        set { processSidebarStore.includeExitedProcesses = newValue }
    }

    var extensionInstallState: MacFSWSystemExtensionInstallState {
        get { systemExtensionStatusStore.installState }
        set { systemExtensionStatusStore.installState = newValue }
    }

    var extensionInstallMessage: String {
        get { systemExtensionStatusStore.installMessage }
        set { systemExtensionStatusStore.installMessage = newValue }
    }

    var llmSettings: MacFSWLLMSettings {
        get { preferencesStore.llmSettings }
        set {
            preferencesStore.llmSettings = newValue
            if !isTestingLLMConnection {
                llmConnectionTestState = .idle
            }
        }
    }

    var defaultStartupPage: MacFSWNavigationPage {
        get { preferencesStore.defaultStartupPage }
        set { preferencesStore.defaultStartupPage = newValue }
    }

    var defaultIncludeExitedProcesses: Bool {
        get { preferencesStore.defaultIncludeExitedProcesses }
        set { preferencesStore.defaultIncludeExitedProcesses = newValue }
    }

    var selectedAnalysisProcessID: MacFSWProcessSummary.ID? {
        get { analysisStore.selectedProcessID }
        set { analysisStore.selectedProcessID = newValue }
    }

    var isAnalysisRunning: Bool {
        get { analysisStore.isRunning }
        set { analysisStore.isRunning = newValue }
    }

    var streamingAnalysisMarkdown: String {
        get { analysisStore.streamingMarkdown }
        set { analysisStore.streamingMarkdown = newValue }
    }

    var analysisStatusText: String {
        get { analysisStore.statusText }
        set { analysisStore.statusText = newValue }
    }

    var analysisRunError: MacFSWConnectionTestError? {
        get { analysisStore.runError }
        set { analysisStore.runError = newValue }
    }

    var analysisResults: [MacFSWAnalysisResult] {
        get { analysisStore.results }
        set { analysisStore.results = newValue }
    }

    var selectedAnalysisID: MacFSWAnalysisResult.ID? {
        get { analysisStore.selectedResultID }
        set { analysisStore.selectedResultID = newValue }
    }

    var llmConnectionTestState: MacFSWConnectionTestState {
        get { analysisStore.connectionTestState }
        set { analysisStore.connectionTestState = newValue }
    }

    var diagnosticLoggingEnabled: Bool {
        get { logStore.isEnabled }
        set { logStore.isEnabled = newValue }
    }

    var diagnosticLogLevel: MacFSWAppLogLevel {
        get { logStore.minimumLevel }
        set { logStore.minimumLevel = newValue }
    }

    var diagnosticLogFilePath: String {
        logStore.logFileURL.path
    }

    var diagnosticLogWriteError: String? {
        logStore.lastWriteError
    }
}
