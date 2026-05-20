import Foundation
import MacFSWCore
import SwiftUI

func format(timestampNS: UInt64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampNS) / 1_000_000_000)
    return date.formatted(date: .omitted, time: .standard)
}

func symbol(for type: MacFSWEventType) -> String {
    switch type {
    case .create: "doc.badge.plus"
    case .open: "eye"
    case .close: "eye.slash"
    case .write: "pencil.line"
    case .rename: "arrow.right"
    case .unlink: "trash"
    case .link: "link"
    case .clone: "plus.square.on.square"
    case .copyfile: "doc.on.doc"
    case .truncate: "scissors"
    case .exchangedata: "arrow.left.arrow.right"
    case .chmod, .chown, .setflags, .setacl: "slider.horizontal.3"
    case .setextattr, .deleteextattr, .utimes: "info.circle"
    case .unknown: "questionmark.circle"
    }
}

func color(for type: MacFSWEventType) -> Color {
    MacFSWOperationBucket.bucket(for: type).color
}
