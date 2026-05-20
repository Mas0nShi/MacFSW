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
        tableView.onSelectionGesture = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleUserSelectionCommit()
        }
        tableView.onClearSelection = { [weak coordinator = context.coordinator] in
            coordinator?.scheduleClearSelection()
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        addColumn("time", "Time", 120, to: tableView)
        addColumn("operation", "Operation", 96, to: tableView)
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
        var onClearSelection: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let clickedRow = row(at: point)
            super.mouseDown(with: event)
            if clickedRow >= 0, clickedRow < numberOfRows, selectedRow != clickedRow {
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }
            onSelectionGesture?()
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 || event.charactersIgnoringModifiers == "\u{1b}" {
                deselectAll(nil)
                onClearSelection?()
                return
            }
            super.keyDown(with: event)
            onSelectionGesture?()
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
        private weak var observedClipView: NSClipView?
        private var rowSnapshots: [Int: MacFSWEventRowSummary] = [:]
        private var lockedUserSelectionRow: Int?
        private var lockedUserSelectionID: UUID?
        private var lockedUserSelectionDeadline: Date?
        private var pendingLiveEdgeReport: Bool?
        private var isLiveEdgeReportScheduled = false

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
            self.onUserSelected = onUserSelected
            self.onClearSelection = onClearSelection
            self.onLiveEdgeChanged = onLiveEdgeChanged
            self.lastRowCount = rowCount
            self.lastCacheVersion = cacheVersion
            self.lastCacheResetSerial = cacheResetSerial
            self.lastResetSerial = resetSerial
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rowCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < rowCount, let tableColumn else {
                return nil
            }
            let identifier = tableColumn.identifier
            let loadedSummary = rowProvider(row)
            if let loadedSummary {
                rowSnapshots[row] = loadedSummary
            }
            let summary = loadedSummary ?? rowSnapshots[row]

            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier

            let textField: NSTextField
            if let existing = cell.textField {
                textField = existing
            } else {
                textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingMiddle
                textField.maximumNumberOfLines = 1
                cell.addSubview(textField)
                cell.textField = textField
                NSLayoutConstraint.activate([
                    textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            textField.stringValue = value(for: identifier.rawValue, summary: summary)
            textField.font = font(for: identifier.rawValue)
            textField.textColor = textColor(for: identifier.rawValue, summary: summary)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSwiftUISelection else {
                return
            }

            scheduleUserSelectionCommit()
        }

        func scheduleUserSelectionCommit() {
            guard let tableView else {
                return
            }
            lockCurrentUserSelection(row: tableView.selectedRow)
            DispatchQueue.main.async { [weak self] in
                self?.commitCurrentSelection()
            }
        }

        private func commitCurrentSelection() {
            guard let tableView else {
                return
            }

            guard tableView.selectedRow >= 0, tableView.selectedRow < rowCount else {
                if rowCount == 0 {
                    onUserSelected(nil, nil)
                }
                return
            }

            let row = tableView.selectedRow
            if let summary = rowProvider(row) ?? rowSnapshots[row] {
                lockedUserSelectionID = summary.id
                if selectedEventID.wrappedValue == summary.id, selectedRow == row {
                    return
                }
                onUserSelected(row, summary.id)
            } else {
                requestRows(row..<min(row + 1, rowCount))
                onUserSelected(row, nil)
            }
        }

        func scheduleClearSelection() {
            clearUserSelectionLock()
            DispatchQueue.main.async { [weak self] in
                self?.onClearSelection()
            }
        }

        func selectVisibleEventIfNeeded() {
            guard let tableView else {
                return
            }
            if shouldPreserveLockedUserSelection(in: tableView) {
                return
            }
            guard let selectedID = selectedEventID.wrappedValue else {
                if let selectedRow, selectedRow >= 0, selectedRow < rowCount {
                    if tableView.selectedRow != selectedRow {
                        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                    }
                } else if tableView.selectedRow >= 0 {
                    tableView.deselectAll(nil)
                }
                return
            }
            if let selectedRow,
               selectedRow >= 0,
               selectedRow < rowCount,
               (rowProvider(selectedRow) ?? rowSnapshots[selectedRow])?.id == selectedID {
                if tableView.selectedRow != selectedRow {
                    tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
                }
                clearUserSelectionLockIfMatched(row: selectedRow, id: selectedID)
                return
            }
            let range = visibleRowRange(in: tableView)
            for row in range {
                if (rowProvider(row) ?? rowSnapshots[row])?.id == selectedID {
                    if tableView.selectedRow != row {
                        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                    clearUserSelectionLockIfMatched(row: row, id: selectedID)
                    return
                }
            }
            if tableView.selectedRow >= 0 {
                tableView.deselectAll(nil)
            }
        }

        func clearUserSelectionLock() {
            lockedUserSelectionRow = nil
            lockedUserSelectionID = nil
            lockedUserSelectionDeadline = nil
        }

        private func lockCurrentUserSelection(row: Int) {
            guard row >= 0, row < rowCount else {
                clearUserSelectionLock()
                return
            }
            lockedUserSelectionRow = row
            lockedUserSelectionID = (rowProvider(row) ?? rowSnapshots[row])?.id
            lockedUserSelectionDeadline = Date().addingTimeInterval(0.22)
        }

        private func shouldPreserveLockedUserSelection(in tableView: NSTableView) -> Bool {
            guard let lockedRow = lockedUserSelectionRow,
                  lockedRow >= 0,
                  lockedRow < rowCount,
                  let deadline = lockedUserSelectionDeadline else {
                return false
            }
            if Date() > deadline {
                clearUserSelectionLock()
                return false
            }
            if let lockedID = lockedUserSelectionID,
               selectedEventID.wrappedValue == lockedID,
               selectedRow == lockedRow {
                clearUserSelectionLock()
                return false
            }
            if lockedUserSelectionID == nil,
               selectedEventID.wrappedValue == nil,
               selectedRow == lockedRow {
                return false
            }
            if tableView.selectedRow != lockedRow {
                tableView.selectRowIndexes(IndexSet(integer: lockedRow), byExtendingSelection: false)
            }
            return true
        }

        private func clearUserSelectionLockIfMatched(row: Int, id: UUID) {
            guard lockedUserSelectionRow == row, lockedUserSelectionID == id else {
                return
            }
            clearUserSelectionLock()
        }

        func observe(scrollView: NSScrollView) {
            stopObserving()
            observedClipView = scrollView.contentView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            observedClipView = nil
        }

        func scrollToLive() {
            guard let tableView, rowCount > 0 else {
                return
            }
            isProgrammaticScroll = true
            tableView.scrollRowToVisible(rowCount - 1)
            lastObservedVisibleBottom = tableView.enclosingScrollView?.contentView.bounds.maxY
            requestVisibleRows()
            reportLiveEdgeIfNeeded(force: true)
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(clearProgrammaticScroll),
                object: nil
            )
            perform(#selector(clearProgrammaticScroll), with: nil, afterDelay: 0)
        }

        func requestVisibleRows() {
            guard let tableView, rowCount > 0 else {
                return
            }
            let range = visibleRowRange(in: tableView)
            guard range.lowerBound < range.upperBound else {
                return
            }
            requestRows(range)
        }

        func applyRowCountChange(from oldCount: Int, to newCount: Int) {
            guard let tableView else {
                return
            }
            tableView.beginUpdates()
            defer { tableView.endUpdates() }
            if newCount > oldCount {
                tableView.insertRows(
                    at: IndexSet(integersIn: oldCount..<newCount),
                    withAnimation: insertionAnimation(for: newCount - oldCount)
                )
            } else if newCount < oldCount {
                for row in newCount..<oldCount {
                    rowSnapshots[row] = nil
                }
                tableView.removeRows(
                    at: IndexSet(integersIn: newCount..<oldCount),
                    withAnimation: removalAnimation(for: oldCount - newCount)
                )
            }
        }

        func reloadVisibleRows(allowUncachedRows: Bool = false) {
            guard let tableView, rowCount > 0 else {
                return
            }
            let range = visibleRowRange(in: tableView)
            guard range.lowerBound < range.upperBound else {
                return
            }
            let rowsToReload = range.filter { row in
                guard row >= 0, row < rowCount else {
                    return false
                }
                guard let summary = rowProvider(row) else {
                    return allowUncachedRows
                }
                return rowSnapshots[row] != summary
            }
            guard !rowsToReload.isEmpty else {
                return
            }
            tableView.reloadData(
                forRowIndexes: IndexSet(rowsToReload),
                columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
            )
        }

        func clearRowSnapshots() {
            rowSnapshots.removeAll(keepingCapacity: true)
        }

        @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.enclosingScrollView,
                  !isProgrammaticScroll,
                  rowCount > 0 else {
                return
            }
            let visibleBottom = clipView.bounds.maxY
            let previousVisibleBottom = lastObservedVisibleBottom
            lastObservedVisibleBottom = visibleBottom
            requestVisibleRows()
            if didScrollUp(from: previousVisibleBottom, to: visibleBottom) || isAtLiveEdge(scrollView) {
                reportLiveEdgeIfNeeded()
            }
        }

        @objc private func clearProgrammaticScroll() {
            isProgrammaticScroll = false
        }

        private func visibleRowRange(in tableView: NSTableView) -> Range<Int> {
            let rows = tableView.rows(in: tableView.visibleRect)
            guard rows.location != NSNotFound, rows.length > 0 else {
                let fallbackUpper = min(rowCount, 80)
                return 0..<fallbackUpper
            }
            let lower = max(0, rows.location)
            let upper = min(rowCount, rows.location + rows.length)
            return lower..<upper
        }

        func isAtLiveEdge() -> Bool {
            guard let scrollView = tableView?.enclosingScrollView else {
                return true
            }
            return isAtLiveEdge(scrollView)
        }

        func reportLiveEdgeIfNeeded(force: Bool = false) {
            let isAtEdge = isAtLiveEdge()
            guard force || lastReportedLiveEdge != isAtEdge else {
                return
            }
            lastReportedLiveEdge = isAtEdge
            pendingLiveEdgeReport = isAtEdge
            guard !isLiveEdgeReportScheduled else {
                return
            }
            isLiveEdgeReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.isLiveEdgeReportScheduled = false
                guard let pendingLiveEdgeReport = self.pendingLiveEdgeReport else {
                    return
                }
                self.pendingLiveEdgeReport = nil
                self.onLiveEdgeChanged(pendingLiveEdgeReport)
            }
        }

        private func isAtLiveEdge(_ scrollView: NSScrollView) -> Bool {
            guard let tableView else {
                return true
            }
            let visibleBottom = scrollView.contentView.bounds.maxY
            let documentBottom = tableView.bounds.height
            return visibleBottom >= documentBottom - max(12, tableView.rowHeight)
        }

        private func didScrollUp(from previousVisibleBottom: CGFloat?, to visibleBottom: CGFloat) -> Bool {
            guard let previousVisibleBottom else {
                return false
            }
            return visibleBottom < previousVisibleBottom - 2
        }

        private func value(for column: String, summary: MacFSWEventRowSummary?) -> String {
            guard let summary else {
                return column == "target" ? "Loading..." : "..."
            }
            return switch column {
            case "time":
                format(timestampNS: summary.timestampNS)
            case "operation":
                summary.eventType.rawValue.uppercased()
            case "process":
                summary.processName
            case "pid":
                "\(summary.pid)"
            case "target":
                summary.targetPath
            case "details":
                summary.detailSummary
            case "signing":
                summary.signingSummary
            default:
                ""
            }
        }

        private func font(for column: String) -> NSFont {
            switch column {
            case "time", "pid":
                .monospacedSystemFont(ofSize: 12, weight: .regular)
            default:
                .systemFont(ofSize: 12)
            }
        }

        private func textColor(for column: String, summary: MacFSWEventRowSummary?) -> NSColor {
            summary == nil ? .secondaryLabelColor : .labelColor
        }

        private func insertionAnimation(for insertedCount: Int) -> NSTableView.AnimationOptions {
            insertedCount <= 120 ? [.slideDown, .effectFade] : []
        }

        private func removalAnimation(for removedCount: Int) -> NSTableView.AnimationOptions {
            removedCount <= 120 ? [.slideUp, .effectFade] : []
        }

        private func format(timestampNS: UInt64) -> String {
            let date = Date(timeIntervalSince1970: TimeInterval(timestampNS) / 1_000_000_000)
            return date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
        }
    }
}
