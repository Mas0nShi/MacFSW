import AppKit
import MacFSWCore

extension EventTableView.Coordinator: NSMenuDelegate {
    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    /// Rebuilt for the row under the pointer each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView, tableView.clickedRow >= 0, let row = rowProvider(tableView.clickedRow) else {
            return
        }
        for (index, group) in EventRowAction.groups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for action in group {
                let item = NSMenuItem(title: action.title(for: row), action: #selector(performRowAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = RowActionPayload(action: action, row: row)
                item.isEnabled = action.isAvailable(for: row)
                menu.addItem(item)
            }
        }
        menu.autoenablesItems = false
    }

    @objc func performRowAction(_ item: NSMenuItem) {
        guard let payload = item.representedObject as? RowActionPayload else {
            return
        }
        onRowAction(payload.action, payload.row)
    }
}

extension EventTableView.Coordinator: NSMenuItemValidation {
    /// The header's menu: one checkable item per column.
    func makeColumnMenu() -> NSMenu {
        let menu = NSMenu()
        for column in EventTableColumn.allCases where column != .path {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc func toggleColumn(_ item: NSMenuItem) {
        guard let identifier = item.representedObject as? String,
              let column = tableView?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier)) else {
            return
        }
        column.isHidden.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleColumn(_:)),
           let identifier = item.representedObject as? String,
           let column = tableView?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier)) {
            item.state = column.isHidden ? .off : .on
        }
        return true
    }
}

private final class RowActionPayload: NSObject {
    let action: EventRowAction
    let row: MacFSWEventRowSummary

    init(action: EventRowAction, row: MacFSWEventRowSummary) {
        self.action = action
        self.row = row
    }
}
