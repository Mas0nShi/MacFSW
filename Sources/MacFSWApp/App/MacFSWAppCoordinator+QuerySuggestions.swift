import Foundation
import MacFSWCore

extension MacFSWAppCoordinator {
    func queryTextEdited() {
        monitorStore.suppressSuggestionsForCurrentText = false
        monitorStore.querySuggestionPreviewBasis = nil
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
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, MacFSWQueryParser.parse(trimmed).expression != nil {
            queryHistoryStore.record(trimmed)
        }
        Task {
            await refreshFilteredEvents()
        }
    }
}
