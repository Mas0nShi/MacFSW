import SwiftUI

struct OperationStatsPane: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    private let buckets: [MacFSWOperationBucket] = [
        .read,
        .create,
        .write,
        .rename,
        .delete,
        .metadata,
        .link,
    ]

    private var summaryByBucket: [MacFSWOperationBucket: MacFSWOperationSummary] {
        Dictionary(uniqueKeysWithValues: model.monitor.operationSummaries.map { ($0.bucket, $0) })
    }

    /// Ranked by count, but holding through near-ties and moving at most
    /// once a second (see `StableRanking`): while recording, counts change
    /// several times a second.
    @State private var order = StableRanking<MacFSWOperationBucket>()

    private func summaries(in order: [MacFSWOperationBucket]) -> [MacFSWOperationSummary] {
        let byBucket = summaryByBucket
        return (order.isEmpty ? buckets : order).map { byBucket[$0] ?? MacFSWOperationSummary(bucket: $0, eventCount: 0) }
    }

    private var ranked: [(id: MacFSWOperationBucket, count: Int)] {
        summaries(in: buckets)
            .sorted { lhs, rhs in
                lhs.eventCount != rhs.eventCount
                    ? lhs.eventCount > rhs.eventCount
                    : bucketRank(lhs.bucket) < bucketRank(rhs.bucket)
            }
            .map { ($0.bucket, $0.eventCount) }
    }

    private func bucketRank(_ bucket: MacFSWOperationBucket) -> Int {
        buckets.firstIndex(of: bucket) ?? buckets.count
    }

    var body: some View {
        let summaries = summaries(in: order.order)
        let total = summaries.reduce(0) { $0 + $1.eventCount }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SidebarSectionHeader("Operations")
                Spacer()
                Text("\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(summaries) { summary in
                    OperationStatRow(summary: summary, total: total)
                }
            }
        }
        .task(id: model.monitor.operationSummaries) {
            var retryAfter: Duration?
            repeat {
                if let delay = retryAfter {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else {
                        return
                    }
                }
                var next = order
                let update = next.update(ranked)
                if update.moved {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        order = next
                    }
                } else {
                    order = next
                }
                retryAfter = update.retryAfter
            } while retryAfter != nil
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 220, alignment: .top)
    }
}

struct OperationStatRow: View {
    let summary: MacFSWOperationSummary
    let total: Int

    private var ratio: Double {
        guard total > 0 else {
            return 0
        }
        return min(1, max(0, Double(summary.eventCount) / Double(total)))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: summary.bucket.symbolName)
                    .font(.caption)
                    .foregroundStyle(summary.bucket.color)
                    .frame(width: 16)
                Text(summary.bucket.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(summary.eventCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    // Only the bar animates; animating the whole row would
                    // re-lay-out its text on every frame.
                    Capsule()
                        .fill(summary.bucket.color.opacity(0.72))
                        .animation(.easeOut(duration: 0.2)) { bar in
                            bar.frame(width: ratio > 0 ? max(2, proxy.size.width * ratio) : 0)
                        }
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
