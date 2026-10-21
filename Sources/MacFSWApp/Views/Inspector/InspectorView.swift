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

enum InspectorSecurityPhase: Equatable {
    case loading
    case loaded(EventSecurityReport)
}

typealias InspectorCopyAction = (_ value: String, _ label: String) -> Void

struct InspectorHeader: View {
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

struct InspectorOperationBadge: View {
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

struct InspectorBadge: Hashable {
    let title: String
    let color: Color
}

func trustStatus(for process: MacFSWProcessIdentity) -> InspectorBadge {
    if process.isPlatformBinary {
        return InspectorBadge(title: "Platform", color: .green)
    }
    if process.signingID?.nonEmpty != nil || process.teamID?.nonEmpty != nil {
        return InspectorBadge(title: "Signed", color: .blue)
    }
    return InspectorBadge(title: "Unsigned", color: .orange)
}

func formattedTimestamp(_ timestampNS: UInt64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampNS) / 1_000_000_000)
    return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
}
