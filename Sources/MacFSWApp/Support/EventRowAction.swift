import Foundation
import MacFSWCore

/// What the event table's context menu offers for one row.
enum EventRowAction: CaseIterable {
    case copyPath
    case copySourcePath
    case copyProcessName
    case showOnlyProcess
    case showOnlyFolder
    case hideProcess
    case revealInFinder

    func title(for row: MacFSWEventRowSummary) -> String {
        switch self {
        case .copyPath: "Copy Path"
        case .copySourcePath: "Copy Source Path"
        case .copyProcessName: "Copy Process Name"
        case .showOnlyProcess: "Show Only \(row.processName) (\(row.pid))"
        case .showOnlyFolder: "Show Only “\(row.folder.lastPathComponentOrRoot)”"
        case .hideProcess: "Hide \(row.processName)"
        case .revealInFinder: "Reveal in Finder"
        }
    }

    /// Filtering actions write query terms, so they are unavailable when a
    /// value cannot be expressed in the query language.
    func isAvailable(for row: MacFSWEventRowSummary) -> Bool {
        switch self {
        case .copySourcePath:
            row.sourcePath != nil
        case .showOnlyFolder:
            MacFSWQueryEditor.term(.path, row.folder) != nil
        case .hideProcess:
            MacFSWQueryEditor.term(.processName, row.processName) != nil
        case .revealInFinder:
            FileManager.default.fileExists(atPath: row.targetPath)
        case .copyPath, .copyProcessName, .showOnlyProcess:
            true
        }
    }

    /// Menu sections, separated in the menu.
    static let groups: [[EventRowAction]] = [
        [.copyPath, .copySourcePath, .copyProcessName],
        [.showOnlyProcess, .showOnlyFolder, .hideProcess],
        [.revealInFinder],
    ]
}

extension MacFSWEventRowSummary {
    var folder: String {
        (targetPath as NSString).deletingLastPathComponent
    }
}

private extension String {
    var lastPathComponentOrRoot: String {
        let component = (self as NSString).lastPathComponent
        return component.isEmpty ? self : component
    }
}
