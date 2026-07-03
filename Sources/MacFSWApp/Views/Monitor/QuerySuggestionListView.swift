import SwiftUI

struct QuerySuggestionListView: View {
    let suggestions: [QuerySuggestion]
    let highlightedIndex: Int?
    let onSelect: (QuerySuggestion) -> Void
    let onHighlight: (Int) -> Void

    private static let rowHeight: CGFloat = 26
    private static let rowSpacing: CGFloat = 2
    private static let listPadding: CGFloat = 6
    private static let maxListHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.rowSpacing) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                            SuggestionRow(
                                suggestion: suggestion,
                                isHighlighted: index == highlightedIndex
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                            .onTapGesture {
                                onSelect(suggestion)
                            }
                            .onHover { hovering in
                                if hovering {
                                    onHighlight(index)
                                }
                            }
                            .id(index)
                        }
                    }
                    .padding(Self.listPadding)
                }
                .scrollIndicators(.never)
                .frame(height: listHeight)
                .onChange(of: highlightedIndex) { _, newValue in
                    if let newValue {
                        proxy.scrollTo(newValue)
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Text("⇥ Preview next")
                Text("↩ Confirm / Run")
                Text("esc Revert")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }

    private var listHeight: CGFloat {
        let count = CGFloat(suggestions.count)
        let content = count * Self.rowHeight
            + max(0, count - 1) * Self.rowSpacing
            + Self.listPadding * 2
        return min(content, Self.maxListHeight)
    }
}

private struct SuggestionRow: View {
    let suggestion: QuerySuggestion
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
            Text(suggestion.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 16)
            if let detail = suggestion.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7))
        .animation(.easeInOut(duration: 0.14), value: isHighlighted)
    }

    private var rowBackground: Color {
        isHighlighted ? Color.accentColor.opacity(0.16) : .clear
    }

    private var symbolName: String {
        switch suggestion.kind {
        case .field:
            "tag"
        case .value:
            "list.bullet"
        case .keyword:
            "arrow.triangle.branch"
        case .history:
            "clock"
        }
    }
}
