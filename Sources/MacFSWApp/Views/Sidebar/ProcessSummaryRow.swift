import SwiftUI

struct ProcessSummaryRow: View {
    let summary: MacFSWProcessSummary
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            ProcessIconView(summary: summary)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayName)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: summary.lifecycle.symbolName)
                        .foregroundStyle(lifecycleColor)
                    if summary.identityCount > 1 {
                        Text("PID reused")
                            .foregroundStyle(.orange)
                    }
                    Text(summary.signingSummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(.caption)
            }
            Spacer()
            Text("\(summary.eventCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
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

    private var lifecycleColor: Color {
        switch summary.lifecycle {
        case .running:
            return .green
        case .exited:
            return .secondary
        case .unknown:
            return .orange
        }
    }
}
