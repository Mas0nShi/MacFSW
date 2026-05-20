import MacFSWCore
import SwiftUI

enum MacFSWOperationBucket: String, CaseIterable, Identifiable, Sendable {
    case read
    case create
    case write
    case rename
    case delete
    case metadata
    case link
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: "READ"
        case .create: "CREATE"
        case .write: "WRITE"
        case .rename: "RENAME"
        case .delete: "DELETE"
        case .metadata: "METADATA"
        case .link: "LINK"
        case .unknown: "UNKNOWN"
        }
    }

    var symbolName: String {
        switch self {
        case .read: "eye"
        case .create: "doc.badge.plus"
        case .write: "pencil.line"
        case .rename: "arrow.left.arrow.right"
        case .delete: "trash"
        case .metadata: "slider.horizontal.3"
        case .link: "link"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .read: .blue
        case .create: .teal
        case .write: .indigo
        case .rename: .purple
        case .delete: .red
        case .metadata: .orange
        case .link: .mint
        case .unknown: .secondary
        }
    }

    static func bucket(for eventType: MacFSWEventType) -> MacFSWOperationBucket {
        switch eventType {
        case .open, .close:
            .read
        case .create:
            .create
        case .write, .clone, .copyfile, .truncate:
            .write
        case .rename, .exchangedata:
            .rename
        case .unlink:
            .delete
        case .chmod, .chown, .setflags, .setacl, .setextattr, .deleteextattr, .utimes:
            .metadata
        case .link:
            .link
        case .unknown:
            .unknown
        }
    }
}

struct MacFSWOperationSummary: Identifiable, Equatable, Sendable {
    var bucket: MacFSWOperationBucket
    var eventCount: Int

    var id: String { bucket.id }
}
