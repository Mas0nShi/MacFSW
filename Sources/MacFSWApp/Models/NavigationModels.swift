import SwiftUI

enum MacFSWFollowMode: String, Equatable {
    case live
    case paused
    case frozen

    var title: String {
        switch self {
        case .live: "Live"
        case .paused: "Paused"
        case .frozen: "Frozen"
        }
    }

    var symbolName: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .paused: "pause.circle"
        case .frozen: "snowflake"
        }
    }
}

enum MacFSWNavigationPage: String, CaseIterable, Identifiable, Sendable {
    case monitor
    case analysis

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor: "Monitor"
        case .analysis: "Analysis"
        }
    }

    var symbolName: String {
        switch self {
        case .monitor: "waveform.path.ecg"
        case .analysis: "sparkles.rectangle.stack"
        }
    }

    var isBeta: Bool {
        switch self {
        case .monitor: false
        case .analysis: true
        }
    }
}

enum MacFSWUILayout {
    static let pageHeaderHeight: CGFloat = 62
}
