import AppKit
import MacFSWCore
import SwiftUI

struct EventTableView: NSViewRepresentable {
    var rowCount: Int
    var cacheVersion: Int
    var cacheResetSerial: Int
    var resetSerial: Int
    @Binding var selectedEventID: UUID?
    var selectedRow: Int?
    var followMode: MacFSWFollowMode
    var scrollToLiveSerial: Int
    var selectionResetSerial: Int
    var rowProvider: (Int) -> MacFSWEventRowSummary?
    var requestRows: (Range<Int>) -> Void
    var onUserWillSelect: (Int) -> Void
    var onUserSelected: (Int?, UUID?) -> Void
    var onClearSelection: () -> Void
    var onLiveEdgeChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedEventID: $selectedEventID,
            selectedRow: selectedRow,
            rowCount: rowCount,
            cacheVersion: cacheVersion,
            cacheResetSerial: cacheResetSerial,
            resetSerial: resetSerial,
            followMode: followMode,
            rowProvider: rowProvider,
            requestRows: requestRows,
            onUserWillSelect: onUserWillSelect,
            onUserSelected: onUserSelected,
            onClearSelection: onClearSelection,
            onLiveEdgeChanged: onLiveEdgeChanged
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = SelectableEventTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 30
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.onUserWillSelect = { [weak coordinator = context.coordinator] row in
            coordinator?.userWillSelect(row: row)
        }
        tableView.onSelectionGesture = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleUserSelectionCommit()
        }
        tableView.onRowSelectionGesture = { [weak coordinator = context.coordinator] row in
            coordinator?.commitUserSelection(row: row)
        }
        tableView.onClearSelection = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleClearSelection()
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        addColumn("time", "Time", 148, to: tableView)
        addColumn("process", "Process", 170, to: tableView)
        addColumn("pid", "PID", 70, to: tableView)
        addColumn("target", "Target", 420, to: tableView)
        addColumn("details", "Details", 280, to: tableView)
        addColumn("signing", "Signing", 180, to: tableView)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.tableView = tableView
        context.coordinator.observe(scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.selectedEventID = $selectedEventID
        context.coordinator.selectedRow = selectedRow
        context.coordinator.rowCount = rowCount
        context.coordinator.cacheVersion = cacheVersion
        context.coordinator.cacheResetSerial = cacheResetSerial
        context.coordinator.resetSerial = resetSerial
        context.coordinator.followMode = followMode
        context.coordinator.rowProvider = rowProvider
        context.coordinator.requestRows = requestRows
        context.coordinator.onUserWillSelect = onUserWillSelect
        context.coordinator.onUserSelected = onUserSelected
        context.coordinator.onClearSelection = onClearSelection
        context.coordinator.onLiveEdgeChanged = onLiveEdgeChanged
        guard let tableView = context.coordinator.tableView else {
            return
        }

        context.coordinator.isApplyingSwiftUISelection = true
        defer {
            context.coordinator.isApplyingSwiftUISelection = false
        }

        let didCacheReset = context.coordinator.lastCacheResetSerial != cacheResetSerial
        let wasAtLiveEdge = context.coordinator.isAtLiveEdge()
        if didCacheReset {
            context.coordinator.clearRowSnapshots()
            context.coordinator.lastCacheResetSerial = cacheResetSerial
        }

        let hasPendingLiveScrollRequest = context.coordinator.lastScrollToLiveSerial != scrollToLiveSerial
        var shouldScrollToLive = hasPendingLiveScrollRequest && followMode == .live
        if context.coordinator.lastResetSerial != resetSerial {
            tableView.reloadData()
            context.coordinator.lastRowCount = rowCount
            context.coordinator.lastResetSerial = resetSerial
            shouldScrollToLive = shouldScrollToLive || (followMode == .live && wasAtLiveEdge)
        } else if context.coordinator.lastRowCount != rowCount {
            let oldCount = context.coordinator.lastRowCount
            context.coordinator.applyRowCountChange(from: context.coordinator.lastRowCount, to: rowCount)
            context.coordinator.lastRowCount = rowCount
            if didCacheReset {
                context.coordinator.reloadVisibleRows(allowUncachedRows: true)
            }
            shouldScrollToLive = shouldScrollToLive || (followMode == .live && rowCount > oldCount && wasAtLiveEdge)
        } else if didCacheReset {
            context.coordinator.reloadVisibleRows(allowUncachedRows: true)
        } else if context.coordinator.lastCacheVersion != cacheVersion {
            context.coordinator.reloadVisibleRows()
        }
        context.coordinator.lastCacheVersion = cacheVersion

        context.coordinator.requestVisibleRows()

        if rowCount == 0 || context.coordinator.lastSelectionResetSerial != selectionResetSerial {
            tableView.deselectAll(nil)
            context.coordinator.clearUserSelectionLock()
        } else {
            context.coordinator.selectVisibleEventIfNeeded()
        }

        if shouldScrollToLive {
            context.coordinator.lastScrollToLiveSerial = scrollToLiveSerial
            context.coordinator.scrollToLive()
        } else if hasPendingLiveScrollRequest, followMode != .live {
            context.coordinator.lastScrollToLiveSerial = scrollToLiveSerial
        } else {
            context.coordinator.reportLiveEdgeIfNeeded()
        }

        context.coordinator.lastSelectionResetSerial = selectionResetSerial
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    private func addColumn(_ identifier: String, _ title: String, _ width: CGFloat, to tableView: NSTableView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = max(48, min(width, 100))
        tableView.addTableColumn(column)
    }

    @MainActor
    final class SelectableEventTableView: NSTableView {
        var onSelectionGesture: (() -> Void)?
        var onRowSelectionGesture: ((Int) -> Void)?
        var onUserWillSelect: ((Int) -> Void)?
        var onClearSelection: (() -> Void)?
        var isTrackingMouseSelection = false

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let clickedRow = row(at: point)
            let hasClickedRow = clickedRow >= 0 && clickedRow < numberOfRows
            if hasClickedRow {
                onUserWillSelect?(clickedRow)
                isTrackingMouseSelection = true
            }
            defer {
                isTrackingMouseSelection = false
            }
            super.mouseDown(with: event)
            guard hasClickedRow else {
                return
            }
            if selectedRow != clickedRow {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            onRowSelectionGesture?(clickedRow)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
                deselectAll(nil)
                onClearSelection?()
                return
            }
            super.keyDown(with: event)
            if selectedRow >= 0, selectedRow < numberOfRows {
                onRowSelectionGesture?(selectedRow)
            } else {
                onSelectionGesture?()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var selectedEventID: Binding<UUID?>
        var selectedRow: Int?
        var rowCount: Int
        var cacheVersion: Int
        var cacheResetSerial: Int
        var resetSerial: Int
        var followMode: MacFSWFollowMode
        var rowProvider: (Int) -> MacFSWEventRowSummary?
        var requestRows: (Range<Int>) -> Void
        var onUserWillSelect: (Int) -> Void
        var onUserSelected: (Int?, UUID?) -> Void
        var onClearSelection: () -> Void
        var onLiveEdgeChanged: (Bool) -> Void
        weak var tableView: NSTableView?
        var isApplyingSwiftUISelection = false
        var isProgrammaticScroll = false
        var lastScrollToLiveSerial = 0
        var lastSelectionResetSerial = 0
        var lastRowCount = 0
        var lastCacheVersion = 0
        var lastCacheResetSerial = 0
        var lastResetSerial = 0
        var lastObservedVisibleBottom: CGFloat?
        var lastReportedLiveEdge: Bool?
        weak var observedClipView: NSClipView?
        var rowSnapshots: [Int: MacFSWEventRowSummary] = [:]
        var lockedUserSelectionRow: Int?
        var lockedUserSelectionID: UUID?
        var lockedUserSelectionDeadline: Date?
        var pendingLiveEdgeReport: Bool?
        var isLiveEdgeReportScheduled = false

        init(
            selectedEventID: Binding<UUID?>,
            selectedRow: Int?,
            rowCount: Int,
            cacheVersion: Int,
            cacheResetSerial: Int,
            resetSerial: Int,
            followMode: MacFSWFollowMode,
            rowProvider: @escaping (Int) -> MacFSWEventRowSummary?,
            requestRows: @escaping (Range<Int>) -> Void,
            onUserWillSelect: @escaping (Int) -> Void,
            onUserSelected: @escaping (Int?, UUID?) -> Void,
            onClearSelection: @escaping () -> Void,
            onLiveEdgeChanged: @escaping (Bool) -> Void
        ) {
            self.selectedEventID = selectedEventID
            self.selectedRow = selectedRow
            self.rowCount = rowCount
            self.cacheVersion = cacheVersion
            self.cacheResetSerial = cacheResetSerial
            self.resetSerial = resetSerial
            self.followMode = followMode
            self.rowProvider = rowProvider
            self.requestRows = requestRows
            self.onUserWillSelect = onUserWillSelect
            self.onUserSelected = onUserSelected
            self.onClearSelection = onClearSelection
            self.onLiveEdgeChanged = onLiveEdgeChanged
            self.lastRowCount = rowCount
            self.lastCacheVersion = cacheVersion
            self.lastCacheResetSerial = cacheResetSerial
            self.lastResetSerial = resetSerial
        }
    }
}
