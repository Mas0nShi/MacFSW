import SwiftUI

struct SidebarNavigationRow: View {
    let page: MacFSWNavigationPage
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: page.symbolName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 20)
            Text(page.title)
                .font(.system(size: 15, weight: .medium))
            Spacer(minLength: 0)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 34)
            .padding(.horizontal, 10)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.14), value: isHovering)
            .animation(.easeInOut(duration: 0.14), value: isSelected)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}

struct CaptureSidebarStatusView: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RecordingIndicatorView(isRecording: model.captureState == .recording)
                Text(model.statusText)
                    .font(.callout.weight(.medium))
                Spacer()
                if model.captureState == .recording {
                    Label(model.followMode.title, systemImage: model.followMode.symbolName)
                        .font(.caption)
                        .foregroundStyle(model.followMode == .live ? .green : .secondary)
                }
            }

            Text(model.captureStatusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}

struct OperationStatsPane: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

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
        Dictionary(uniqueKeysWithValues: model.operationSummaries.map { ($0.bucket, $0) })
    }

    private var rankedSummaries: [MacFSWOperationSummary] {
        buckets.map { bucket in
            summaryByBucket[bucket] ?? MacFSWOperationSummary(bucket: bucket, eventCount: 0)
        }
        .sorted { lhs, rhs in
            if lhs.eventCount != rhs.eventCount {
                return lhs.eventCount > rhs.eventCount
            }
            return bucketRank(lhs.bucket) < bucketRank(rhs.bucket)
        }
    }

    private var total: Int {
        rankedSummaries.reduce(0) { $0 + $1.eventCount }
    }

    private var animationSignature: String {
        rankedSummaries
            .map { "\($0.id):\($0.eventCount)" }
            .joined(separator: "|")
    }

    private func bucketRank(_ bucket: MacFSWOperationBucket) -> Int {
        buckets.firstIndex(of: bucket) ?? buckets.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SidebarSectionHeader("Operations")
                Spacer()
                Text("\(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(rankedSummaries) { summary in
                    OperationStatRow(summary: summary, total: total)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: animationSignature)
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
                    Capsule()
                        .fill(summary.bucket.color.opacity(0.72))
                        .frame(width: ratio > 0 ? max(2, proxy.size.width * ratio) : 0)
                        .animation(.easeInOut(duration: 0.22), value: ratio)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
