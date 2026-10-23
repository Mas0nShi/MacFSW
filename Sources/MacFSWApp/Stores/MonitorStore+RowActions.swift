import AppKit
import MacFSWCore

extension MonitorStore {
    func perform(_ action: EventRowAction, on row: MacFSWEventRowSummary) {
        switch action {
        case .copyPath:
            copy(row.targetPath)
        case .copySourcePath:
            row.sourcePath.map(copy)
        case .copyProcessName:
            copy(row.processName)
        case .showOnlyProcess:
            pinProcess(row.pid)
        case .showOnlyFolder:
            addQueryTerm(MacFSWQueryEditor.term(.path, row.folder))
        case .hideProcess:
            addQueryTerm(MacFSWQueryEditor.term(.processName, row.processName, comparison: .equals, negated: true))
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.targetPath)])
        }
    }

    private func addQueryTerm(_ term: MacFSWQueryExpression?) {
        guard let term else {
            return
        }
        applyEditedQuery(MacFSWQueryEditor.editing(queryText, adding: [term]))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
