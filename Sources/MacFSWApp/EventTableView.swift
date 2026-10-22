import AppKit
import QuartzCore
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
    /// The user scrolled away from (false) or back to (true) the newest row.
    var onFollowChanged: (Bool) -> Void
    var onRowAction: (EventRowAction, MacFSWEventRowSummary) -> Void

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
            onFollowChanged: onFollowChanged
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = SelectableEventTableView()
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 26
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
        tableView.menu = context.coordinator.makeContextMenu()
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        for column in EventTableColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = min(column.width, 80)
            tableColumn.resizingMask = column.isFlexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableColumn.isHidden = column.isHiddenByDefault
            tableView.addTableColumn(tableColumn)
        }
        // Remembers widths, order, and hidden columns; set after the
        // columns exist so the saved layout is applied to them.
        tableView.autosaveName = "MacFSW.EventTable"
        tableView.autosaveTableColumns = true
        tableView.headerView?.menu = context.coordinator.makeColumnMenu()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.tableView = tableView
        context.coordinator.observe(scrollView: scrollView)
        // Column autoresizing only reacts to resizes; fit the flexible
        // columns to the first real width so none start off-screen.
        DispatchQueue.main.async { [weak tableView] in
            tableView?.sizeToFit()
        }
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
        context.coordinator.onFollowChanged = onFollowChanged
        context.coordinator.onRowAction = onRowAction
        guard let tableView = context.coordinator.tableView else {
            return
        }

        context.coordinator.isApplyingSwiftUISelection = true
        defer {
            context.coordinator.isApplyingSwiftUISelection = false
        }

        let coordinator = context.coordinator
        let didCacheReset = coordinator.lastCacheResetSerial != cacheResetSerial
        if didCacheReset {
            coordinator.clearRowSnapshots()
            coordinator.lastCacheResetSerial = cacheResetSerial
        }

        let didReset = coordinator.lastResetSerial != resetSerial
        if didReset {
            tableView.reloadData()
            coordinator.lastRowCount = rowCount
            coordinator.lastResetSerial = resetSerial
        } else if coordinator.lastRowCount != rowCount {
            coordinator.applyRowCountChange(from: coordinator.lastRowCount, to: rowCount)
            coordinator.lastRowCount = rowCount
            if didCacheReset {
                coordinator.reloadVisibleRows(allowUncachedRows: true)
            }
        } else if didCacheReset {
            coordinator.reloadVisibleRows(allowUncachedRows: true)
        } else if coordinator.lastCacheVersion != cacheVersion {
            coordinator.reloadVisibleRows()
        }
        coordinator.lastCacheVersion = cacheVersion

        coordinator.requestVisibleRows()

        if rowCount == 0 || coordinator.lastSelectionResetSerial != selectionResetSerial {
            tableView.deselectAll(nil)
            coordinator.clearUserSelectionLock()
        } else {
            coordinator.selectVisibleEventIfNeeded()
        }
        coordinator.lastSelectionResetSerial = selectionResetSerial

        coordinator.syncFollowing(with: followMode)
        if coordinator.lastScrollToLiveSerial != scrollToLiveSerial {
            coordinator.lastScrollToLiveSerial = scrollToLiveSerial
            coordinator.jumpToLiveEdge(gliding: !didReset)
        } else if didReset, followMode == .live {
            coordinator.jumpToLiveEdge(gliding: false)
        } else {
            // New rows may have arrived; the display link glides to them.
            coordinator.startFollowing()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
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
        var onFollowChanged: (Bool) -> Void
        var onRowAction: (EventRowAction, MacFSWEventRowSummary) -> Void = { _, _ in }
        weak var tableView: NSTableView?
        var isApplyingSwiftUISelection = false
        var isProgrammaticScroll = false
        var isFollowing = true
        var hasUnreportedFollowChange = false
        var followLink: CADisplayLink?
        var lastFollowFrame: CFTimeInterval?
        var lastFollowJump: CFTimeInterval = 0
        var lastClipBounds: NSRect?
        var lastScrollToLiveSerial = 0
        var lastSelectionResetSerial = 0
        var lastRowCount = 0
        var lastCacheVersion = 0
        var lastCacheResetSerial = 0
        var lastResetSerial = 0
        weak var observedClipView: NSClipView?
        var rowSnapshots: [Int: MacFSWEventRowSummary] = [:]
        var lockedUserSelectionRow: Int?
        var lockedUserSelectionID: UUID?
        var lockedUserSelectionDeadline: Date?

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
            onFollowChanged: @escaping (Bool) -> Void
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
            self.onFollowChanged = onFollowChanged
            self.lastRowCount = rowCount
            self.lastCacheVersion = cacheVersion
            self.lastCacheResetSerial = cacheResetSerial
            self.lastResetSerial = resetSerial
        }
    }
}
