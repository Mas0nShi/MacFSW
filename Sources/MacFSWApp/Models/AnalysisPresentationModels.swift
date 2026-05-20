import Foundation

struct MacFSWAnalysisResult: Identifiable, Equatable, Sendable {
    var id = UUID()
    var processID: MacFSWProcessSummary.ID
    var processDisplayName: String
    var createdAt: Date
    var durationSeconds: Double
    var scope: String
    var providerSummary: String
    var eventCount: Int
    var payloadEventCount: Int
    var pathCount: Int
    var operationCount: Int
    var markdown: String
}
