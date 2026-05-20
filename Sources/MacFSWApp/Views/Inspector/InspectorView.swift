import AppKit
import MacFSWCore
import SwiftUI

struct InspectorView: View {
    let event: MacFSWFileEvent?
    let isLoading: Bool

    @State private var showsForensics = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let event {
                    InspectorHeader(event: event, onCopy: copy)

                    InspectorGroup("Target", systemImage: "scope") {
                        InspectorField(
                            "Path",
                            value: event.targetPath,
                            style: .path,
                            importance: .primary,
                            onCopy: copy
                        )

                        if let sourcePath = event.sourcePath?.nonEmpty {
                            InspectorField(
                                "Source",
                                value: sourcePath,
                                style: .path,
                                importance: .secondary,
                                onCopy: copy
                            )
                        }
                    }

                    if !event.parameters.isEmpty {
                        InspectorGroup("Parameters", systemImage: "slider.horizontal.3") {
                            ForEach(event.parameters) { parameter in
                                InspectorField(parameter.label, value: parameter.value, onCopy: copy)
                            }
                        }
                    }

                    InspectorGroup("Process Evidence", systemImage: "signature") {
                        InspectorField("Executable", value: event.process.executablePath, style: .path, onCopy: copy)
                        InspectorField("Signing ID", value: event.process.signingID.displayValue, onCopy: copy)
                        if let teamID = event.process.teamID?.nonEmpty {
                            InspectorField("Team ID", value: teamID, onCopy: copy)
                        }
                    }

                    InspectorDisclosureGroup(
                        "Forensics",
                        systemImage: "curlybraces",
                        isExpanded: $showsForensics
                    ) {
                        InspectorField("Event ID", value: event.id.uuidString, style: .token, onCopy: copy)
                        InspectorField("Sequence", value: "\(event.sequence)", style: .number, onCopy: copy)
                        InspectorField("Time", value: formattedTimestamp(event.timestampNS), onCopy: copy)
                        InspectorField("Timestamp NS", value: "\(event.timestampNS)", style: .number, onCopy: copy)
                        InspectorField("Audit Token", value: event.process.auditToken, style: .token, onCopy: copy)
                        InspectorField("CDHash", value: event.process.cdhash.displayValue, style: .token, onCopy: copy)
                        InspectorField("Raw Type", value: event.rawEventType, style: .token, onCopy: copy)
                        InspectorField("Raw Value", value: event.rawEventTypeValue.map(String.init) ?? "Not available", style: .number, onCopy: copy)
                        InspectorField("ES Version", value: "\(event.rawEventVersion)", style: .number, onCopy: copy)
                        InspectorField("Flags", value: "\(event.flags)", style: .number, onCopy: copy)
                    }
                } else if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading Event")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ContentUnavailableView("No Event Selected", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func copy(_ value: String, label: String) {
        copyToPasteboard(value)
    }
}

private typealias InspectorCopyAction = (_ value: String, _ label: String) -> Void

private struct InspectorHeader: View {
    let event: MacFSWFileEvent
    let onCopy: InspectorCopyAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                ProcessIconView(executablePath: event.process.executablePath, fallbackSymbolName: "terminal")
                    .frame(width: 24, height: 24)
                    .padding(8)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 5) {
                    Text(event.process.processName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)

                Spacer(minLength: 6)

                InspectorOperationBadge(event: event)

                InspectorCopyButton(
                    value: event.process.processName,
                    label: "Process",
                    onCopy: onCopy
                )
            }

            HStack(spacing: 6) {
                InspectorMetadataChip("PID \(event.process.pid)")
                InspectorPrivilegeChip(uid: event.uid, gid: event.gid)
                InspectorTrustChip(status: trustStatus(for: event.process))
                Spacer(minLength: 0)
                InspectorMetadataChip(format(timestampNS: event.timestampNS))
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct InspectorOperationBadge: View {
    let event: MacFSWFileEvent

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(event.eventType.rawValue.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(color(for: event.eventType))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color(for: event.eventType).opacity(0.10), in: Capsule())

            if let subtitle = operationSubtitle {
                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Operation \(event.eventType.rawValue)")
    }

    private var operationSubtitle: String? {
        let eventTitle = event.eventType.rawValue.uppercased()
        let classTitle = MacFSWOperationBucket.bucket(for: event.eventType).title
        return classTitle == eventTitle ? nil : classTitle
    }
}

private struct InspectorGroup<Content: View>: View {
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

private struct InspectorDisclosureGroup<Content: View>: View {
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

private struct InspectorSectionHeader: View {
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

private struct InspectorPanel<Content: View>: View {
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

private enum InspectorValueStyle {
    case standard
    case path
    case token
    case number
}

private enum InspectorFieldImportance {
    case primary
    case secondary
}

private struct InspectorField: View {
    let title: String
    let value: String
    let style: InspectorValueStyle
    let importance: InspectorFieldImportance
    let onCopy: InspectorCopyAction

    @State private var isExpanded = false

    init(
        _ title: String,
        value: String,
        style: InspectorValueStyle = .standard,
        importance: InspectorFieldImportance = .secondary,
        onCopy: @escaping InspectorCopyAction
    ) {
        self.title = title
        self.value = value
        self.style = style
        self.importance = importance
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

private struct InspectorRowContainer<Content: View>: View {
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

private struct InspectorMetadataChip: View {
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

private struct InspectorPrivilegeChip: View {
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

private struct InspectorTrustChip: View {
    let status: InspectorTrustStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.10), in: Capsule())
    }
}

private struct InspectorCopyButton: View {
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

private struct InspectorTrustStatus {
    let title: String
    let color: Color
}

private func trustStatus(for process: MacFSWProcessIdentity) -> InspectorTrustStatus {
    if process.isPlatformBinary {
        return InspectorTrustStatus(title: "Platform", color: .green)
    }
    if process.signingID?.nonEmpty != nil || process.teamID?.nonEmpty != nil {
        return InspectorTrustStatus(title: "Signed", color: .blue)
    }
    return InspectorTrustStatus(title: "Unsigned", color: .orange)
}

@MainActor
private func copyToPasteboard(_ value: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
}

private func formattedTimestamp(_ timestampNS: UInt64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampNS) / 1_000_000_000)
    return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
}

private extension Optional where Wrapped == String {
    var displayValue: String {
        guard let value = self?.nonEmpty else {
            return "Not available"
        }
        return value
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
