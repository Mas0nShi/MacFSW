import MacFSWCore

enum OperationSummaryReducer {
    static func operationSummaries(from summaries: [MacFSWOperationEventSummary]) -> [MacFSWOperationSummary] {
        var counts: [MacFSWOperationBucket: Int] = [:]
        for summary in summaries {
            let bucket = MacFSWOperationBucket.bucket(for: summary.eventType)
            counts[bucket, default: 0] += summary.eventCount
        }
        return sortedOperationSummaries(from: counts)
    }

    static func applying(
        rows: [MacFSWEventRowSummary],
        to operationSummaries: [MacFSWOperationSummary]
    ) -> [MacFSWOperationSummary] {
        guard !rows.isEmpty else {
            return operationSummaries
        }
        var counts = Dictionary(uniqueKeysWithValues: operationSummaries.map { ($0.bucket, $0.eventCount) })
        for row in rows {
            let bucket = MacFSWOperationBucket.bucket(for: row.eventType)
            counts[bucket, default: 0] += 1
        }
        return sortedOperationSummaries(from: counts)
    }

    static func sortedOperationSummaries(from counts: [MacFSWOperationBucket: Int]) -> [MacFSWOperationSummary] {
        counts
            .filter { $0.value > 0 }
            .map { MacFSWOperationSummary(bucket: $0.key, eventCount: $0.value) }
            .sorted { lhs, rhs in
                if lhs.eventCount != rhs.eventCount {
                    return lhs.eventCount > rhs.eventCount
                }
                let lhsIndex = MacFSWOperationBucket.allCases.firstIndex(of: lhs.bucket) ?? 0
                let rhsIndex = MacFSWOperationBucket.allCases.firstIndex(of: rhs.bucket) ?? 0
                return lhsIndex < rhsIndex
            }
    }
}
