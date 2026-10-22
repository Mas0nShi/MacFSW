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
            StatusBar()
        }
    }
}

struct MonitorCommandBar: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        @Bindable var monitor = model.monitor
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                CommandBarTextField(
                    text: $monitor.queryText,
                    placeholder: "(op:rename OR op:unlink) path:/Library NOT platform:true",
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

            Button {
                model.recordButtonTapped()
            } label: {
                Label(recordButtonTitle, systemImage: recordButtonSymbol)
            }
            .disabled(model.session.isReadOnly || model.session.captureState == .stopping)
            .help(model.session.isReadOnly ? Self.readOnlyHelp : "")

            if model.shouldShowJumpToLive {
                Button {
                    model.monitor.jumpToLive()
                } label: {
                    Label("Jump to Live", systemImage: "arrow.down.to.line")
                }
            }

            Button {
                model.clearView()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(model.session.isReadOnly || (model.monitor.visibleEventCount == 0 && model.session.captureStats.deliveredEvents == 0))
            .help(model.session.isReadOnly ? Self.readOnlyHelp : "")

        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.background)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private static let readOnlyHelp = "Opened sessions are read-only. Start a new session (⌘N) to record."

    private var recordButtonTitle: String {
        if model.session.captureState == .recording {
            return "Stop"
        }
        if model.session.captureHealth.fullDiskAccessHint {
            return "Open Full Disk Access"
        }
        return model.extensionStatus.installState == .ready ? "Record" : "Enable Extension"
    }

    private var recordButtonSymbol: String {
        if model.session.captureState == .recording {
            return "stop.circle.fill"
        }
        if model.session.captureHealth.fullDiskAccessHint {
            return "lock.shield"
        }
        return model.extensionStatus.installState == .ready ? "record.circle" : "puzzlepiece.extension"
    }
}
