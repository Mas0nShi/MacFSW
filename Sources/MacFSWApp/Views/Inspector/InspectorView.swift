import AppKit
import MacFSWCore
import SwiftUI

struct InspectorView: View {
    let event: MacFSWFileEvent?
    let isLoading: Bool

    @State private var showsForensics = false
    @State private var showsEntitlements = true
    @State private var securityPhase: InspectorSecurityPhase = .loading

    private static let scrollTopAnchor = "inspector-scroll-top"

    private var loadedReport: EventSecurityReport? {
        if case .loaded(let report) = securityPhase {
            return report
        }
        return nil
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            scrollContent(resetWith: scrollProxy)
        }
    }

    private func scrollContent(resetWith scrollProxy: ScrollViewProxy) -> some View {
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
                            permissions: loadedReport?.targetPermissions,
                            onCopy: copy
                        )

                        if let sourcePath = event.sourcePath?.nonEmpty {
                            InspectorField(
                                "Source",
                                value: sourcePath,
                                style: .path,
                                importance: .secondary,
                                permissions: loadedReport?.sourcePermissions,
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

                    InspectorProcessSection(event: event, phase: securityPhase, onCopy: copy)

                    if let entitlements = loadedReport?.executable?.entitlements, !entitlements.isEmpty {
                        InspectorDisclosureGroup(
                            "Entitlements (\(entitlements.count))",
                            systemImage: "checkmark.seal",
                            isExpanded: $showsEntitlements
                        ) {
                            ForEach(entitlements) { entitlement in
                                InspectorEntitlementRow(entitlement: entitlement, onCopy: copy)
                            }
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
            .id(Self.scrollTopAnchor)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: event?.id) {
            // A scroll offset carried over from a longer event would land beyond
            // the new (still loading) content and leave the lazy stack blank.
            scrollProxy.scrollTo(Self.scrollTopAnchor, anchor: .top)
        }
        .task(id: event?.id) {
            securityPhase = .loading
            guard let event else {
                return
            }
            let report = await ExecutableSecurityInspector.shared.report(
                executablePath: event.process.executablePath,
                targetPath: event.targetPath,
                sourcePath: event.sourcePath?.nonEmpty
            )
            guard !Task.isCancelled else {
                return
            }
            securityPhase = .loaded(report)
        }
    }

    private func copy(_ value: String, label: String) {
        copyToPasteboard(value)
    }
}

private enum InspectorSecurityPhase: Equatable {
    case loading
    case loaded(EventSecurityReport)
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

private struct InspectorProcessSection: View {
    let event: MacFSWFileEvent
    let phase: InspectorSecurityPhase
    let onCopy: InspectorCopyAction

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            InspectorGroup("Process", systemImage: "cpu") {
                InspectorRowContainer {
                    InspectorChipFlow(spacing: 6) {
                        ForEach(badges, id: \.self) { badge in
                            InspectorBadgeChip(badge: badge)
                        }
                    }
                }

                InspectorField(
                    "Executable",
                    value: event.process.executablePath,
                    style: .path,
                    permissions: executable?.permissions,
                    onCopy: onCopy
                )
                InspectorField("Signing ID", value: event.process.signingID.displayValue, onCopy: onCopy)
                if let teamID = event.process.teamID?.nonEmpty {
                    InspectorField("Team ID", value: teamID, onCopy: onCopy)
                }
            }

            if executable != nil {
                Text("Sandbox, entitlements, and permissions read from the executable currently on disk; it may differ from the binary at event time.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var executable: ExecutableSecuritySnapshot? {
        if case .loaded(let report) = phase {
            return report.executable
        }
        return nil
    }

    private var badges: [InspectorBadge] {
        var badges = [trustStatus(for: event.process)]

        guard case .loaded(let report) = phase else {
            return badges
        }
        guard let executable = report.executable else {
            badges.append(InspectorBadge(title: "Not on Disk", color: .secondary))
            return badges
        }

        switch executable.sandbox {
        case .sandboxed:
            badges.append(InspectorBadge(title: "Sandboxed", color: .green))
        case .notSandboxed:
            badges.append(InspectorBadge(title: "Not Sandboxed", color: .secondary))
        case .unknown:
            badges.append(InspectorBadge(title: "Sandbox Unknown", color: .secondary))
        }
        if executable.hasHardenedRuntime {
            badges.append(InspectorBadge(title: "Hardened Runtime", color: .blue))
        }
        if executable.permissions.isSetUserID {
            badges.append(InspectorBadge(title: "SUID \(executable.permissions.owner)", color: .orange))
        }
        if executable.permissions.isSetGroupID {
            badges.append(InspectorBadge(title: "SGID \(executable.permissions.group)", color: .orange))
        }
        return badges
    }
}

private struct InspectorEntitlementRow: View {
    let entitlement: EntitlementEntry
    let onCopy: InspectorCopyAction

    var body: some View {
        InspectorRowContainer {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if !entitlement.items.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            keyText
                            Spacer(minLength: 6)
                            Text("\(entitlement.items.count) items")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(entitlement.items.enumerated()), id: \.offset) { _, item in
                                Text(item)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(item)
                            }
                        }
                        .padding(.leading, 10)
                    } else if hasCompactValue {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            keyText
                            Spacer(minLength: 6)
                            valueText
                        }
                    } else {
                        keyText
                        valueText
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                InspectorCopyButton(
                    value: copyPayload,
                    label: entitlement.key,
                    onCopy: onCopy
                )
                .frame(width: 22)
            }
        }
    }

    private var copyPayload: String {
        if entitlement.items.isEmpty {
            return "\(entitlement.key) = \(entitlement.value)"
        }
        return (["\(entitlement.key) ="] + entitlement.items).joined(separator: "\n")
    }

    private var keyText: some View {
        Text(entitlement.key)
            .font(.system(.callout, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var valueText: some View {
        Text(entitlement.value)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hasCompactValue: Bool {
        entitlement.value.count <= 24 && !entitlement.value.contains("\n")
    }
}

private struct InspectorChipFlow: Layout {
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

private struct InspectorPermissionText: View {
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

private struct InspectorBadgeChip: View {
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

private struct InspectorBadge: Hashable {
    let title: String
    let color: Color
}

private func trustStatus(for process: MacFSWProcessIdentity) -> InspectorBadge {
    if process.isPlatformBinary {
        return InspectorBadge(title: "Platform", color: .green)
    }
    if process.signingID?.nonEmpty != nil || process.teamID?.nonEmpty != nil {
        return InspectorBadge(title: "Signed", color: .blue)
    }
    return InspectorBadge(title: "Unsigned", color: .orange)
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
