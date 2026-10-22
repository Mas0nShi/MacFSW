import AppKit
import MacFSWCore
import SwiftUI

extension EventTableView.Coordinator {
        func numberOfRows(in tableView: NSTableView) -> Int {
            rowCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < rowCount,
                  let tableColumn,
                  let column = EventTableColumn(rawValue: tableColumn.identifier.rawValue) else {
                return nil
            }
            let loadedSummary = rowProvider(row)
            if let loadedSummary {
                rowSnapshots[row] = loadedSummary
            }
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? EventTableCellView
                ?? EventTableCellView(identifier: tableColumn.identifier)
            column.configure(cell, with: loadedSummary ?? rowSnapshots[row])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSwiftUISelection else {
                return
            }
            if let tableView = notification.object as? EventTableView.SelectableEventTableView,
               tableView.isTrackingMouseSelection {
                return
            }

            scheduleUserSelectionCommit()
        }

        func userWillSelect(row: Int) {
            guard row >= 0, row < rowCount else {
                return
            }
            lockCurrentUserSelection(row: row)
            onUserWillSelect(row)
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

        func commitUserSelection(row: Int) {
            lockCurrentUserSelection(row: row)
            commitSelection(row: row)
        }

        private func commitCurrentSelection() {
            guard let tableView else {
                return
            }

            commitSelection(row: tableView.selectedRow)
        }

        private func commitSelection(row: Int) {
            guard row >= 0, row < rowCount else {
                if rowCount == 0 {
                    onUserSelected(nil, nil)
                }
                return
            }

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
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(userWillScroll(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
        }

        /// The user takes over: stop pulling the view toward the live edge.
        @objc func userWillScroll(_ notification: Notification) {
            guard isAnimatingToLive, let clipView = observedClipView else {
                return
            }
            isAnimatingToLive = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                clipView.animator().setBoundsOrigin(clipView.bounds.origin)
            }
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            observedClipView = nil
        }

        /// Brings the newest row into view. Live follow animates the scroll
        /// over about one render interval, so batches arriving every
        /// ~140 ms read as a steady scroll instead of a jump per batch.
        func scrollToLive(animated: Bool = false) {
            guard let tableView, rowCount > 0, let scrollView = tableView.enclosingScrollView else {
                return
            }
            let clipView = scrollView.contentView
            let bottom = tableView.rect(ofRow: rowCount - 1).maxY
            let target = clipView.constrainBoundsRect(NSRect(
                origin: NSPoint(x: clipView.bounds.origin.x, y: bottom - clipView.bounds.height),
                size: clipView.bounds.size
            )).origin

            guard animated else {
                isProgrammaticScroll = true
                isAnimatingToLive = false
                clipView.setBoundsOrigin(target)
                scrollView.reflectScrolledClipView(clipView)
                didFinishScrollToLive()
                NSObject.cancelPreviousPerformRequests(
                    withTarget: self,
                    selector: #selector(clearProgrammaticScroll),
                    object: nil
                )
                perform(#selector(clearProgrammaticScroll), with: nil, afterDelay: 0)
                return
            }

            isAnimatingToLive = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                clipView.animator().setBoundsOrigin(target)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isAnimatingToLive else {
                        return
                    }
                    self.isAnimatingToLive = false
                    scrollView.reflectScrolledClipView(clipView)
                    self.didFinishScrollToLive()
                }
            }
        }

        private func didFinishScrollToLive() {
            lastObservedVisibleBottom = tableView?.enclosingScrollView?.contentView.bounds.maxY
            requestVisibleRows()
            reportLiveEdgeIfNeeded(force: true)
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
                    withAnimation: []
                )
            } else if newCount < oldCount {
                for row in newCount..<oldCount {
                    rowSnapshots[row] = nil
                }
                tableView.removeRows(
                    at: IndexSet(integersIn: newCount..<oldCount),
                    withAnimation: []
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
}
