import SwiftUI

struct MonitorView: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        @Bindable var monitor = model.monitor
        VStack(spacing: 0) {
            MonitorCommandBar()
                .zIndex(1)
            EventTableView(
                rowCount: model.monitor.visibleEventCount,
                cacheVersion: model.monitor.rowCacheVersion,
                cacheResetSerial: model.monitor.rowCacheResetSerial,
                resetSerial: model.monitor.tableResetSerial,
                selectedEventID: $monitor.selectedEventID,
                selectedRow: model.monitor.selectedRow,
                followMode: model.monitor.followMode,
                scrollToLiveSerial: model.monitor.scrollToLiveSerial,
                selectionResetSerial: model.monitor.selectionResetSerial,
                rowProvider: { row in
                    model.monitor.cachedRow(at: row)
                },
                requestRows: { range in
                    model.monitor.requestRows(range)
                },
                onUserWillSelect: { row in
                    model.monitor.prepareEventSelection(row: row)
                },
                onUserSelected: { row, eventID in
                    model.monitor.selectEvent(eventID, row: row)
                },
                onClearSelection: {
                    model.monitor.clearEventSelection()
                },
                onLiveEdgeChanged: { isAtLiveEdge in
                    model.monitor.liveEdgeChanged(isAtLiveEdge)
                },
                onRowAction: { action, row in
                    model.monitor.perform(action, on: row)
                }
            )
            .overlay {
                MonitorEmptyState()
            }
            StatusBar()
        }
    }
}

struct MonitorCommandBar: View {
    @Environment(MacFSWAppCoordinator.self) private var model
    @State private var showsSyntaxHelp = false

    var body: some View {
        @Bindable var monitor = model.monitor
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                CommandBarTextField(
                    text: $monitor.queryText,
                    placeholder: "Filter events — e.g. path:/Library op:rename",
                    isSuggestionListVisible: model.monitor.isQuerySuggestionListVisible,
                    onEditingChanged: {
                        model.monitor.queryTextEdited()
                        model.monitor.scheduleQueryRefresh()
                    },
                    onSubmit: {
                        model.monitor.submitQuery()
                    },
                    onMoveHighlight: { delta in
                        model.monitor.moveSuggestionHighlight(by: delta)
                    },
                    onCycleHighlight: { delta in
                        model.monitor.cycleSuggestionHighlight(by: delta)
                    },
                    onAcceptSuggestion: {
                        model.monitor.acceptHighlightedSuggestion()
                    },
                    onCancelSuggestions: {
                        model.monitor.cancelQuerySuggestions()
                    },
                    onDismissSuggestions: {
                        model.monitor.dismissQuerySuggestions()
                    },
                    highlight: { text in
                        model.monitor.queryHighlightRuns(for: text)
                    },
                    fillCommitSerial: model.monitor.queryFillCommitSerial,
                    fillCommitBasis: model.monitor.queryFillCommitBasis,
                    previewBasis: model.monitor.querySuggestionPreviewBasis
                )

                if let warning = model.monitor.queryDiagnosticSummary {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(warning)
                        .transition(.opacity)
                }

                if model.monitor.isApplyingFilter {
                    ProgressView()
                        .controlSize(.small)
                } else if !model.monitor.queryText.isEmpty {
                    Button {
                        model.monitor.clearQuery()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear query")
                }

                Button {
                    showsSyntaxHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Query syntax")
                .popover(isPresented: $showsSyntaxHelp, arrowEdge: .bottom) {
                    QuerySyntaxHelpView { example in
                        showsSyntaxHelp = false
                        model.monitor.applyEditedQuery(example)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topLeading) {
                if model.monitor.isQuerySuggestionListVisible {
                    QuerySuggestionListView(
                        suggestions: model.monitor.querySuggestions,
                        highlightedIndex: model.monitor.querySuggestionHighlight,
                        onSelect: { suggestion in
                            model.monitor.acceptSuggestion(suggestion)
                        },
                        onHighlight: { index in
                            model.monitor.querySuggestionHighlight = index
                        }
                    )
                    .frame(maxWidth: 520, alignment: .topLeading)
                    .offset(y: 36)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.14), value: model.monitor.isQuerySuggestionListVisible)
            .animation(.easeInOut(duration: 0.14), value: model.monitor.queryDiagnosticSummary == nil)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.background)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// Shown over the table when it has no rows, explaining why and offering
/// the one action that changes that.
private struct MonitorEmptyState: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        if model.monitor.visibleEventCount == 0, !model.monitor.isApplyingFilter, let content {
            ContentUnavailableView {
                Label(content.title, systemImage: content.symbol)
            } description: {
                Text(content.detail)
            } actions: {
                if let action = content.action {
                    Button(action.title, action: action.perform)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .padding(.top, 28) // keep the column headers visible
        }
    }

    private struct Content {
        var title: String
        var symbol: String
        var detail: String
        var action: (title: String, perform: () -> Void)?
    }

    private var content: Content? {
        let session = model.session
        if session.captureState == .recording || session.captureState == .connecting {
            return model.monitor.queryText.isEmpty
                ? Content(title: "Waiting for Events", symbol: "dot.radiowaves.left.and.right", detail: "File-system activity appears here as it happens.")
                : noMatches
        }
        if session.captureStats.deliveredEvents > 0 {
            return noMatches
        }
        if session.isReadOnly {
            return Content(title: "No Events", symbol: "tray", detail: "This session was saved without any events.")
        }
        if model.extensionStatus.installState != .ready {
            return Content(
                title: "Endpoint Extension Needed",
                symbol: "puzzlepiece.extension",
                detail: "MacFSW records through its Endpoint Extension. Enable it, then approve it in System Settings.",
                action: ("Enable Extension", { model.activateSystemExtension() })
            )
        }
        return Content(
            title: "No Events Yet",
            symbol: "record.circle",
            detail: "Record, reproduce the behavior you want to study, then stop. Press ⌘R to start.",
            action: ("Record", { model.recordButtonTapped() })
        )
    }

    private var noMatches: Content {
        Content(
            title: "No Matching Events",
            symbol: "line.3.horizontal.decrease.circle",
            detail: "Nothing recorded matches \(model.monitor.queryText).",
            action: ("Clear Query", { model.monitor.clearQuery() })
        )
    }
}
