import MacFSWCore
import SwiftUI

struct SidebarSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct MacFSWBetaBadge: View {
    var body: some View {
        Text("Beta")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.orange)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.10), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.orange.opacity(0.24), lineWidth: 1)
            }
            .accessibilityLabel("Beta feature")
    }
}

struct RecordingIndicatorView: View {
    let isRecording: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            let opacity = isRecording ? 0.55 + 0.45 * sin(phase * .pi) : 1
            let scale = isRecording ? 0.92 + 0.12 * sin(phase * .pi) : 1

            Image(systemName: isRecording ? "record.circle.fill" : "circle")
                .foregroundStyle(isRecording ? .red : .secondary)
                .scaleEffect(scale)
                .opacity(opacity)
                .frame(width: 18, height: 18)
        }
    }
}

struct SectionView<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(5)
        }
    }
}

