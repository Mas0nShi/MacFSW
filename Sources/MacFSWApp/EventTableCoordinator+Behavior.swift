import AppKit
import MacFSWCore
import SwiftUI

extension EventTableView.Coordinator {
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

            if identifier.rawValue == "time" {
                return eventTimeCell(in: tableView, identifier: identifier, summary: summary)
            }

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
            cell.toolTip = nil
            return cell
        }

        private func eventTimeCell(
            in tableView: NSTableView,
            identifier: NSUserInterfaceItemIdentifier,
            summary: MacFSWEventRowSummary?
        ) -> NSView {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = identifier

            let imageView: NSImageView
            let textField: NSTextField
            if let existing = cell.imageView {
                imageView = existing
            } else {
                imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                cell.addSubview(imageView)
                cell.imageView = imageView
            }
            if let existing = cell.textField {
                textField = existing
            } else {
                textField = NSTextField(labelWithString: "")
                textField.translatesAutoresizingMaskIntoConstraints = false
                textField.lineBreakMode = .byTruncatingTail
                textField.maximumNumberOfLines = 1
                cell.addSubview(textField)
                cell.textField = textField
            }

            if imageView.constraints.isEmpty {
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                    imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    imageView.widthAnchor.constraint(equalToConstant: 18),
                    imageView.heightAnchor.constraint(equalToConstant: 18),
                    textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
                    textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }

            let symbolName = summary.map { symbol(for: $0.eventType) } ?? "ellipsis"
            let label = summary.map(operationTooltip(for:)) ?? "Loading operation"
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            image?.isTemplate = true

            imageView.image = image
            imageView.contentTintColor = summary.map { operationColor(for: $0.eventType) } ?? .secondaryLabelColor
            imageView.setAccessibilityLabel(label)
            textField.stringValue = summary.map { format(timestampNS: $0.timestampNS) } ?? "..."
            textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textField.textColor = textColor(for: "time", summary: summary)
            cell.toolTip = label
            return cell
        }

        private func operationTooltip(for summary: MacFSWEventRowSummary) -> String {
            let bucket = MacFSWOperationBucket.bucket(for: summary.eventType).title
            return "\(summary.eventType.rawValue.uppercased()) · \(bucket)"
        }

        private func operationColor(for type: MacFSWEventType) -> NSColor {
            switch MacFSWOperationBucket.bucket(for: type) {
            case .read:
                .systemBlue
            case .create:
                .systemTeal
            case .write:
                .systemIndigo
            case .rename:
                .systemPurple
            case .delete:
                .systemRed
            case .metadata:
                .systemOrange
            case .link:
                .systemMint
            case .unknown:
                .secondaryLabelColor
            }
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
