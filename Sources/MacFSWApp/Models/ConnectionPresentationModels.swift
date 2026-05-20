import SwiftUI

struct MacFSWConnectionTestError: Equatable {
    var title: String
    var message: String
    var diagnostic: String
}

enum MacFSWConnectionTestState: Equatable {
    case idle
    case testing
    case succeeded(String)
    case failed(MacFSWConnectionTestError)

    var badgeTitle: String {
        switch self {
        case .idle:
            "Not Tested"
        case .testing:
            "Testing"
        case .succeeded:
            "OK"
        case .failed:
            "Failed"
        }
    }

    var badgeSymbolName: String {
        switch self {
        case .idle:
            "circle"
        case .testing:
            "clock"
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .idle:
            .secondary
        case .testing:
            .secondary
        case .succeeded:
            .green
        case .failed:
            .orange
        }
    }
}
