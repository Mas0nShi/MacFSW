import AppKit
import SwiftUI

struct InspectorChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width
            width = max(width, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct InspectorGroup<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            InspectorSectionHeader(title: title, systemImage: systemImage)
            InspectorPanel {
                content
            }
        }
    }
}

struct InspectorDisclosureGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    let content: Content

    init(_ title: String, systemImage: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    InspectorSectionHeader(title: title, systemImage: systemImage)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")

            if isExpanded {
                InspectorPanel {
                    content
                }
                .transition(.opacity)
            }
        }
    }
}

struct InspectorSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

struct InspectorPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

enum InspectorValueStyle {
    case standard
    case path
    case token
    case number
}

enum InspectorFieldImportance {
    case primary
    case secondary
}

struct InspectorField: View {
    let title: String
    let value: String
    let style: InspectorValueStyle
    let importance: InspectorFieldImportance
    let permissions: FilePermissionSnapshot?
    let onCopy: InspectorCopyAction

    @State private var isExpanded = false

    init(
        _ title: String,
        value: String,
        style: InspectorValueStyle = .standard,
        importance: InspectorFieldImportance = .secondary,
        permissions: FilePermissionSnapshot? = nil,
        onCopy: @escaping InspectorCopyAction
    ) {
        self.title = title
        self.value = value
        self.style = style
        self.importance = importance
        self.permissions = permissions
        self.onCopy = onCopy
    }

    var body: some View {
        InspectorRowContainer {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.caption.weight(importance == .primary ? .semibold : .regular))
                        .foregroundStyle(.secondary)

                    Text(displayValue)
                        .font(valueFont)
                        .foregroundStyle(displayValue == "Not available" ? .tertiary : .primary)
                        .lineLimit(isExpanded ? nil : collapsedLineLimit)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let permissions {
                        InspectorPermissionText(permissions: permissions)
                    }
                }
                .layoutPriority(1)

                VStack(spacing: 5) {
                    if displayValue != "Not available" {
                        InspectorCopyButton(value: value, label: title, onCopy: onCopy)
                    }

                    if canExpand {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
                        .accessibilityLabel(isExpanded ? "Collapse \(title)" : "Expand \(title)")
                    }
                }
                .frame(width: 22)
            }
        }
    }

    private var displayValue: String {
        value.nonEmpty ?? "Not available"
    }

    private var canExpand: Bool {
        switch style {
        case .path:
            displayValue.count > 72
        case .token:
            displayValue.count > 48
        case .standard:
            displayValue.count > 52 || displayValue.contains("\n")
        case .number:
            false
        }
    }

    private var collapsedLineLimit: Int {
        switch style {
        case .path:
            importance == .primary ? 3 : 2
        case .token:
            2
        case .standard:
            2
        case .number:
            1
        }
    }

    private var valueFont: Font {
        switch style {
        case .path, .token, .number:
            .system(.callout, design: .monospaced)
        case .standard:
            .callout
        }
    }
}

struct InspectorPermissionText: View {
    let permissions: FilePermissionSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Text(styledBits)
            Text("\(permissions.owner):\(permissions.group)")
                .foregroundStyle(.secondary)
            Text(permissions.octal)
                .foregroundStyle(.tertiary)
            if !permissions.fileFlags.isEmpty {
                Text(styledFlags)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.tail)
        .contextMenu {
            Button("Copy Permissions") {
                copyToPasteboard(permissions.displayText)
            }
        }
        .accessibilityLabel("Permissions \(permissions.displayText)")
    }

    private var styledBits: AttributedString {
        let symbolic = Array(permissions.symbolic)
        var result = AttributedString()

        if symbolic[0] != "-" {
            var typeMark = AttributedString(String(symbolic[0]))
            typeMark.foregroundColor = .secondary
            result += typeMark + AttributedString(" ")
        }

        for (offset, character) in symbolic.dropFirst().enumerated() {
            if offset > 0, offset % 3 == 0 {
                result += AttributedString(" ")
            }
            var bit = AttributedString(String(character))
            bit.foregroundColor = "sStT".contains(character) ? .orange : .secondary
            result += bit
        }
        return result
    }

    private var styledFlags: AttributedString {
        var result = AttributedString()
        for (index, flag) in permissions.fileFlags.enumerated() {
            if index > 0 {
                result += AttributedString(" ")
            }
            var name = AttributedString(flag.name)
            name.foregroundColor = flag.isSystemEnforced ? .blue : .secondary
            result += name
        }
        return result
    }
}

struct InspectorRowContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Divider()
                    .padding(.leading, 12)
            }
    }
}

struct InspectorMetadataChip: View {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

struct InspectorPrivilegeChip: View {
    let uid: UInt32
    let gid: UInt32

    var body: some View {
        Text("UID/GID \(uid)/\(gid)")
            .font(.caption.weight(uid == 0 ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(uid == 0 ? .orange : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((uid == 0 ? Color.orange.opacity(0.11) : Color.primary.opacity(0.05)), in: Capsule())
    }
}

struct InspectorBadgeChip: View {
    let badge: InspectorBadge

    var body: some View {
        Text(badge.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(badge.color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badge.color.opacity(0.10), in: Capsule())
    }
}

struct InspectorCopyButton: View {
    let value: String
    let label: String
    let onCopy: InspectorCopyAction

    @State private var isCopied = false
    @State private var copySerial = 0

    var body: some View {
        Button {
            animateCopyFeedback()
            onCopy(value, label)
        } label: {
            ZStack {
                Image(systemName: "doc.on.doc")
                    .opacity(isCopied ? 0 : 1)
                    .scaleEffect(isCopied ? 0.72 : 1)

                Image(systemName: "checkmark.circle.fill")
                    .opacity(isCopied ? 1 : 0)
                    .scaleEffect(isCopied ? 1 : 0.72)
            }
            .font(.caption.weight(.medium))
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isCopied ? .green : .secondary)
        .scaleEffect(isCopied ? 1.12 : 1)
        .animation(.spring(response: 0.20, dampingFraction: 0.72), value: isCopied)
        .help(isCopied ? "Copied \(label)" : "Copy \(label)")
        .accessibilityLabel(isCopied ? "Copied \(label)" : "Copy \(label)")
    }

    private func animateCopyFeedback() {
        copySerial += 1
        let serial = copySerial
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard copySerial == serial else {
                return
            }
            isCopied = false
        }
    }
}

@MainActor
func copyToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

extension Optional where Wrapped == String {
    var displayValue: String {
        guard let value = self?.nonEmpty else {
            return "Not available"
        }
        return value
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
