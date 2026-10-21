import Foundation
import Observation
import MacFSWCore

@MainActor
@Observable
final class MonitorStore {
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
    var selectedProcessID: MacFSWProcessSummary.ID?
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
}
