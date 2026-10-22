import Foundation
import Observation
import MacFSWCore

/// The event table, command bar, and inspector selection for the current
/// session: query parsing and suggestions, the paged row window over the
/// event store, and live-tail rendering of newly captured events.
@MainActor
@Observable
final class MonitorStore {
    @ObservationIgnored
    var eventStore: MacFSWSQLiteEventStore
    @ObservationIgnored
    let processSidebar: ProcessSidebarStore
    @ObservationIgnored
    let queryHistory: QueryHistoryStore
    @ObservationIgnored
    var onError: (any Error) -> Void = { _ in }

    var visibleEventCount = 0
    var rowCacheVersion = 0
    var rowCacheResetSerial = 0
    var tableResetSerial = 0
    var selectedEventID: UUID?
    var selectedRow: Int?
    var selectedEvent: MacFSWFileEvent?
    var selectedEventIsLoading = false
    var queryText = ""
    var followMode: MacFSWFollowMode = .live
    var unseenEventCount = 0
    var isViewingLiveEdge = true
    var scrollToLiveSerial = 0
    var selectionResetSerial = 0
    var lastUpdatedAt: Date?
    var operationSummaries: [MacFSWOperationSummary] = []
    var isApplyingFilter = false
    var querySuggestions: [QuerySuggestion] = []
    var querySuggestionHighlight: Int?
    var isQuerySuggestionListVisible = false
    var queryDiagnostics: [MacFSWQueryDiagnostic] = []
    /// Last front-end parse of `queryText`; lets suggestions, diagnostics,
    /// and highlighting share one parse per keystroke.
    @ObservationIgnored
    var lastQueryParse: MacFSWQueryParseResult?
    @ObservationIgnored
    var suppressSuggestionsForCurrentText = false
    /// User-typed text captured when Tab previewing starts, restored on Esc.
    var querySuggestionPreviewBasis: String?
    /// Bumped when a suggestion is COMMITTED (accept, not preview): the
    /// field registers exactly one undo step, from `queryFillCommitBasis`
    /// (what the user typed) to the committed text. Tab previews are
    /// ephemeral and never enter the undo stack.
    var queryFillCommitSerial = 0
    var queryFillCommitBasis = ""
    /// Faceted value candidates for the current (prefix conditions, field)
    /// pair; single-entry cache scoped to one suggestion session.
    @ObservationIgnored
    var facetValues: [(value: String, detail: String?)] = []
    @ObservationIgnored
    var facetValueKey: String?
    @ObservationIgnored
    var facetRequestKey: String?
    @ObservationIgnored
    var facetTask: Task<Void, Never>?

    @ObservationIgnored
    var refreshTask: Task<Void, Never>?
    @ObservationIgnored
    var renderTask: Task<Void, Never>?
    @ObservationIgnored
    var filterTask: Task<Void, Never>?
    @ObservationIgnored
    var operationSummaryTask: Task<Void, Never>?
    @ObservationIgnored
    var selectedEventLoadTask: Task<Void, Never>?
    @ObservationIgnored
    var selectedEventLoadGeneration = 0
    @ObservationIgnored
    var snapshotCleanupTask: Task<Void, Never>?
    @ObservationIgnored
    var retiredSnapshotIDs: Set<String> = []
    @ObservationIgnored
    var activeQuery = MacFSWEventQuery()
    @ObservationIgnored
    var activeSnapshot: MacFSWEventResultSnapshot?
    let rowPageSize = 256
    let maxCachedRowPages = 96
    let maxDirectAppendCacheRows = 1_024
    @ObservationIgnored
    var rowCache: [Int: MacFSWEventRowSummary] = [:]
    @ObservationIgnored
    var loadedRowPages: Set<Int> = []
    @ObservationIgnored
    var inFlightRowPages: Set<Int> = []
    @ObservationIgnored
    var rowLoadTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored
    var rowPageAccessTicks: [Int: Int] = [:]
    @ObservationIgnored
    var rowPageAccessTick = 0
    @ObservationIgnored
    var lastRequestedRowRange: Range<Int> = 0..<0
    @ObservationIgnored
    var totalMatchingEventCount = 0
    @ObservationIgnored
    var pendingVisibleMatchCount = 0
    @ObservationIgnored
    var pendingVisibleRowSummaries: [MacFSWEventRowSummary] = []
    @ObservationIgnored
    var queryGeneration = 0
    @ObservationIgnored
    var liveRenderGeneration = 0

    init(eventStore: MacFSWSQLiteEventStore, processSidebar: ProcessSidebarStore, queryHistory: QueryHistoryStore) {
        self.eventStore = eventStore
        self.processSidebar = processSidebar
        self.queryHistory = queryHistory
    }

    func reportError(_ error: any Error) {
        onError(error)
    }

    /// Points the monitor at a different event store (new or opened session)
    /// and drops every piece of state derived from the previous one.
    func reset(eventStore newStore: MacFSWSQLiteEventStore, followMode newFollowMode: MacFSWFollowMode) {
        cancelAllWork()
        eventStore = newStore
        queryText = ""
        activeQuery = MacFSWEventQuery()
        resetDerivedState(followMode: newFollowMode)
    }

    /// Clears what was derived from the store's events while keeping the
    /// current query, for when the store itself was emptied.
    func resetAfterClear() {
        cancelAllWork()
        activeQuery = MacFSWQueryParser.parse(queryText)
        resetDerivedState(followMode: .live)
    }

    func cancelAllWork() {
        renderTask?.cancel()
        renderTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        filterTask?.cancel()
        filterTask = nil
        cancelSelectedEventLoad()
        cancelSnapshotCleanup()
        cancelRowLoads()
    }

    private func resetDerivedState(followMode newFollowMode: MacFSWFollowMode) {
        visibleEventCount = 0
        totalMatchingEventCount = 0
        resetRowCache(resetTable: true)
        selectedEventID = nil
        selectedRow = nil
        selectedEvent = nil
        selectedEventIsLoading = false
        isApplyingFilter = false
        activeSnapshot = nil
        operationSummaries = []
        followMode = newFollowMode
        unseenEventCount = 0
        isViewingLiveEdge = true
        scrollToLiveSerial += 1
        selectionResetSerial += 1
        lastUpdatedAt = Date()
    }

    func scheduleQueryRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else {
                return
            }
            await self?.refreshFilteredEvents()
        }
    }

    func applyOperationSummaryDelta(from rows: [MacFSWEventRowSummary]) {
        operationSummaries = OperationSummaryReducer.applying(rows: rows, to: operationSummaries)
    }

    func prepareForLiveCapture() {
        followMode = .live
        unseenEventCount = 0
        isViewingLiveEdge = true
        scrollToLiveSerial += 1
    }

    func captureStopped() {
        followMode = .paused
        unseenEventCount = 0
        isViewingLiveEdge = true
    }
}
