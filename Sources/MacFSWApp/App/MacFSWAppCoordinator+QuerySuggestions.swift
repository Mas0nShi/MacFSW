import Foundation
import MacFSWCore

extension MacFSWAppCoordinator {
    /// The single entry for parsing the command bar's text: every path that
    /// interprets `queryText` goes through here so the diagnostics shown in
    /// the UI can never drift from the query actually applied.
    @discardableResult
    func parseCurrentQueryText() -> MacFSWQueryParseResult {
        let result = MacFSWQueryParser.parseDetailed(queryText)
        monitorStore.lastQueryParse = result
        queryDiagnostics = result.diagnostics
        return result
    }

    func queryHighlightRuns(for text: String) -> [QueryHighlighter.AttributeRun] {
        let result: MacFSWQueryParseResult
        if let cached = monitorStore.lastQueryParse, cached.tokens.source == text {
            result = cached
        } else {
            result = MacFSWQueryParser.parseDetailed(text)
        }
        return QueryHighlighter.attributeRuns(for: result)
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
        var context = QuerySuggestionEngine.context(
            from: processSidebarStore.processSummaries,
            history: queryHistoryStore.entries
        )
        applyFacetCandidates(into: &context)
        querySuggestions = QuerySuggestionEngine.suggestions(for: queryText, context: context)
        isQuerySuggestionListVisible = !querySuggestions.isEmpty
        querySuggestionHighlight = nil
    }

    // MARK: - Faceted value candidates

    /// When the caret sits in a facetable field's value position AND the
    /// query already carries conditions, value candidates come from the
    /// event store filtered by those conditions ("only processes that have
    /// write events"), fetched once per (conditions, field) pair. Until the
    /// fetch lands — and whenever it fails — the full in-memory candidate
    /// lists stay in effect.
    private func applyFacetCandidates(into context: inout QuerySuggestionContext) {
        let cursor = MacFSWQueryCursorContext.trailing(of: queryText)
        guard case .fieldValue(let descriptor, _, _, _, _) = cursor.position,
              isFacetable(descriptor.valueKind) else {
            cancelFacetPrefetch()
            return
        }
        let prefixQuery = MacFSWQueryParser.parse(cursor.prefixText)
        guard prefixQuery.expression != nil else {
            cancelFacetPrefetch()
            return
        }

        let key = prefixQuery.text + "\u{1F}" + descriptor.canonicalKey
        if monitorStore.facetValueKey == key {
            assignFacetValues(monitorStore.facetValues, for: descriptor.valueKind, into: &context)
            return
        }
        scheduleFacetPrefetch(key: key, field: descriptor.field, query: prefixQuery)
    }

    private func isFacetable(_ kind: MacFSWQueryValueKind) -> Bool {
        switch kind {
        case .processName, .pid, .executable, .signingID, .teamID:
            return true
        case .eventType, .operationClass, .boolean, .path, .numeric, .text:
            return false
        }
    }

    private func assignFacetValues(
        _ values: [(value: String, detail: String?)],
        for kind: MacFSWQueryValueKind,
        into context: inout QuerySuggestionContext
    ) {
        switch kind {
        case .processName:
            context.processNames = values
        case .pid:
            context.pids = values
        case .executable:
            context.executables = values
        case .signingID:
            context.signingIDs = values
        case .teamID:
            context.teamIDs = values
        case .eventType, .operationClass, .boolean, .path, .numeric, .text:
            break
        }
    }

    private func scheduleFacetPrefetch(key: String, field: MacFSWQueryField, query: MacFSWEventQuery) {
        guard monitorStore.facetRequestKey != key else {
            return
        }
        monitorStore.facetTask?.cancel()
        monitorStore.facetRequestKey = key
        let store = eventStore
        monitorStore.facetTask = Task { [weak self] in
            let values: [MacFSWFacetValue]?
            do {
                values = try await store.distinctValues(for: field, matching: query, limit: 50)
            } catch {
                values = nil
            }
            guard !Task.isCancelled, let self, self.monitorStore.facetRequestKey == key else {
                return
            }
            self.monitorStore.facetTask = nil
            guard let values else {
                // Failed fetch: fall back to the full candidate lists and
                // allow a later retry.
                self.monitorStore.facetRequestKey = nil
                return
            }
            self.monitorStore.facetValues = values.map {
                (value: $0.value, detail: $0.count == 1 ? "1 matching event" : "\($0.count) matching events")
            }
            self.monitorStore.facetValueKey = key
            self.refreshQuerySuggestions()
        }
    }

    private func cancelFacetPrefetch() {
        monitorStore.facetTask?.cancel()
        monitorStore.facetTask = nil
        monitorStore.facetRequestKey = nil
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
        // Facet counts are only guaranteed fresh within one dropdown session.
        cancelFacetPrefetch()
        monitorStore.facetValueKey = nil
        monitorStore.facetValues = []
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
