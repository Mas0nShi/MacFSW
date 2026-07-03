import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            MonitorCommandBar()
                .zIndex(1)
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
                onUserWillSelect: { row in
                    model.prepareEventSelection(row: row)
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
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                CommandBarTextField(
                    text: $model.queryText,
                    placeholder: "(op:rename OR op:unlink) path:/Library NOT platform:true",
                    isSuggestionListVisible: model.isQuerySuggestionListVisible,
                    onEditingChanged: {
                        model.queryTextEdited()
                        model.scheduleQueryRefresh()
                    },
                    onSubmit: {
                        model.submitQuery()
                    },
                    onMoveHighlight: { delta in
                        model.moveSuggestionHighlight(by: delta)
                    },
                    onCycleHighlight: { delta in
                        model.cycleSuggestionHighlight(by: delta)
                    },
                    onAcceptSuggestion: {
                        model.acceptHighlightedSuggestion()
                    },
                    onCancelSuggestions: {
                        model.cancelQuerySuggestions()
                    },
                    onDismissSuggestions: {
                        model.dismissQuerySuggestions()
                    },
                    highlight: { text in
                        model.queryHighlightRuns(for: text)
                    },
                    fillCommitSerial: model.queryFillCommitSerial,
                    fillCommitBasis: model.queryFillCommitBasis
                )

                if let warning = model.queryDiagnosticSummary {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(warning)
                        .transition(.opacity)
                }

                if model.isApplyingFilter {
                    ProgressView()
                        .controlSize(.small)
                } else if !model.queryText.isEmpty {
                    Button {
                        model.dismissQuerySuggestions()
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
            .overlay(alignment: .topLeading) {
                if model.isQuerySuggestionListVisible {
                    QuerySuggestionListView(
                        suggestions: model.querySuggestions,
                        highlightedIndex: model.querySuggestionHighlight,
                        onSelect: { suggestion in
                            model.acceptSuggestion(suggestion)
                        },
                        onHighlight: { index in
                            model.querySuggestionHighlight = index
                        }
                    )
                    .frame(maxWidth: 520, alignment: .topLeading)
                    .offset(y: 36)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.14), value: model.isQuerySuggestionListVisible)
            .animation(.easeInOut(duration: 0.14), value: model.queryDiagnosticSummary == nil)

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
