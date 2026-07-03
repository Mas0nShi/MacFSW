import Foundation
import MacFSWCore

extension MacFSWAppCoordinator {
    /// The single entry for parsing the command bar's text: every path that
    /// interprets `queryText` goes through here so the diagnostics shown in
    /// the UI can never drift from the query actually applied.
    @discardableResult
    func parseCurrentQueryText() -> MacFSWQueryParseResult {
        let result = MacFSWQueryParser.parseDetailed(queryText)
        queryDiagnostics = result.diagnostics
        return result
    }

    var queryDiagnosticSummary: String? {
        guard let first = queryDiagnostics.first else {
            return nil
        }
        let extra = queryDiagnostics.count - 1
        return extra > 0 ? "\(first.message) (+\(extra) more)" : first.message
    }

    func queryTextEdited() {
        monitorStore.suppressSuggestionsForCurrentText = false
        monitorStore.querySuggestionPreviewBasis = nil
        parseCurrentQueryText()
        refreshQuerySuggestions()
    }

    func refreshQuerySuggestions() {
        guard !monitorStore.suppressSuggestionsForCurrentText else {
            return
        }
        let context = QuerySuggestionEngine.context(
            from: processSidebarStore.processSummaries,
            history: queryHistoryStore.entries
        )
        querySuggestions = QuerySuggestionEngine.suggestions(for: queryText, context: context)
        isQuerySuggestionListVisible = !querySuggestions.isEmpty
        querySuggestionHighlight = nil
    }

    func moveSuggestionHighlight(by delta: Int) {
        guard isQuerySuggestionListVisible else {
            monitorStore.suppressSuggestionsForCurrentText = false
            refreshQuerySuggestions()
            if isQuerySuggestionListVisible {
                querySuggestionHighlight = QuerySuggestionEngine.nextHighlight(
                    current: nil,
                    delta: delta,
                    count: querySuggestions.count
                )
            }
            return
        }
        querySuggestionHighlight = QuerySuggestionEngine.nextHighlight(
            current: querySuggestionHighlight,
            delta: delta,
            count: querySuggestions.count
        )
    }

    /// Tab previews candidates in place: the field shows what confirming
    /// would produce, computed against the text the user actually typed.
    /// The suggestion list stays frozen on that basis while cycling.
    func cycleSuggestionHighlight(by delta: Int) {
        guard isQuerySuggestionListVisible, !querySuggestions.isEmpty else {
            return
        }
        if monitorStore.querySuggestionPreviewBasis == nil {
            monitorStore.querySuggestionPreviewBasis = queryText
        }
        querySuggestionHighlight = QuerySuggestionEngine.cycledHighlight(
            current: querySuggestionHighlight,
            delta: delta,
            count: querySuggestions.count
        )
        if let highlight = querySuggestionHighlight, querySuggestions.indices.contains(highlight) {
            queryText = querySuggestions[highlight].resultText
        }
    }

    @discardableResult
    func acceptHighlightedSuggestion() -> Bool {
        guard isQuerySuggestionListVisible,
              let highlight = querySuggestionHighlight,
              querySuggestions.indices.contains(highlight) else {
            return false
        }
        acceptSuggestion(querySuggestions[highlight])
        return true
    }

    func acceptSuggestion(_ suggestion: QuerySuggestion) {
        monitorStore.querySuggestionPreviewBasis = nil
        queryText = suggestion.resultText
        scheduleQueryRefresh()
        switch suggestion.kind {
        case .field:
            monitorStore.suppressSuggestionsForCurrentText = false
            refreshQuerySuggestions()
        case .value, .keyword, .history:
            dismissQuerySuggestions()
        }
    }

    func dismissQuerySuggestions() {
        isQuerySuggestionListVisible = false
        querySuggestionHighlight = nil
        monitorStore.querySuggestionPreviewBasis = nil
        monitorStore.suppressSuggestionsForCurrentText = true
    }

    /// Esc: restore what the user typed before Tab previewing, then close.
    func cancelQuerySuggestions() {
        if let basis = monitorStore.querySuggestionPreviewBasis {
            queryText = basis
        }
        dismissQuerySuggestions()
    }

    func submitQuery() {
        dismissQuerySuggestions()
        let result = parseCurrentQueryText()
        if !result.query.text.isEmpty, result.query.expression != nil {
            queryHistoryStore.record(result.query.text)
        }
        Task {
            await refreshFilteredEvents()
        }
    }
}
