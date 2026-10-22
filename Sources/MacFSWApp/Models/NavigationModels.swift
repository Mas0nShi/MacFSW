import SwiftUI

/// Whether the monitor scrolls to new events as they arrive.
enum MacFSWFollowMode: String, Equatable {
    case live
    case paused
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
