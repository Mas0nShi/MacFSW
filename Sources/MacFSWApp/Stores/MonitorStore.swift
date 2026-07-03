import Foundation
import MacFSWCore

@MainActor
final class MonitorStore: ObservableObject {
    @Published var visibleEventCount = 0
    @Published var rowCacheVersion = 0
    @Published var rowCacheResetSerial = 0
    @Published var tableResetSerial = 0
    @Published var selectedEventID: UUID?
    @Published var selectedRow: Int?
    @Published var selectedEvent: MacFSWFileEvent?
    @Published var selectedEventIsLoading = false
    @Published var queryText = ""
    @Published var followMode: MacFSWFollowMode = .live
    @Published var unseenEventCount = 0
    @Published var isViewingLiveEdge = true
    @Published var scrollToLiveSerial = 0
    @Published var selectionResetSerial = 0
    @Published var lastUpdatedAt: Date?
    @Published var operationSummaries: [MacFSWOperationSummary] = []
    @Published var selectedProcessID: MacFSWProcessSummary.ID?
    @Published var isApplyingFilter = false
    @Published var querySuggestions: [QuerySuggestion] = []
    @Published var querySuggestionHighlight: Int?
    @Published var isQuerySuggestionListVisible = false
    @Published var queryDiagnostics: [MacFSWQueryDiagnostic] = []
    /// Last front-end parse of `queryText`; lets suggestions, diagnostics,
    /// and highlighting share one parse per keystroke.
    var lastQueryParse: MacFSWQueryParseResult?
    var suppressSuggestionsForCurrentText = false
    /// User-typed text captured when Tab previewing starts, restored on Esc.
    var querySuggestionPreviewBasis: String?
    /// Bumped when a suggestion is COMMITTED (accept, not preview): the
    /// field registers exactly one undo step, from `queryFillCommitBasis`
    /// (what the user typed) to the committed text. Tab previews are
    /// ephemeral and never enter the undo stack.
    @Published var queryFillCommitSerial = 0
    var queryFillCommitBasis = ""
    /// Faceted value candidates for the current (prefix conditions, field)
    /// pair; single-entry cache scoped to one suggestion session.
    var facetValues: [(value: String, detail: String?)] = []
    var facetValueKey: String?
    var facetRequestKey: String?
    var facetTask: Task<Void, Never>?

    var refreshTask: Task<Void, Never>?
    var renderTask: Task<Void, Never>?
    var filterTask: Task<Void, Never>?
    var operationSummaryTask: Task<Void, Never>?
    var selectedEventLoadTask: Task<Void, Never>?
    var selectedEventLoadGeneration = 0
    var snapshotCleanupTask: Task<Void, Never>?
    var retiredSnapshotIDs: Set<String> = []
    var activeQuery = MacFSWEventQuery()
    var activeSnapshot: MacFSWEventResultSnapshot?
    let rowPageSize = 256
    let maxCachedRowPages = 96
    let maxDirectAppendCacheRows = 1_024
    var rowCache: [Int: MacFSWEventRowSummary] = [:]
    var loadedRowPages: Set<Int> = []
    var inFlightRowPages: Set<Int> = []
    var rowLoadTasks: [Int: Task<Void, Never>] = [:]
    var rowPageAccessTicks: [Int: Int] = [:]
    var rowPageAccessTick = 0
    var lastRequestedRowRange: Range<Int> = 0..<0
    var totalMatchingEventCount = 0
    var pendingVisibleMatchCount = 0
    var pendingVisibleRowSummaries: [MacFSWEventRowSummary] = []
    var queryGeneration = 0
    var liveRenderGeneration = 0
}
