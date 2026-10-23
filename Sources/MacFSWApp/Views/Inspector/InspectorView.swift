import MacFSWCore
import SwiftUI

struct InspectorView: View {
    let event: MacFSWFileEvent?
    let isLoading: Bool

    // Process-level detail is the same for every event of a process, so it
    // starts folded; the choice sticks while stepping through events.
    @AppStorage("MacFSW.Inspector.ShowsEntitlements") private var showsEntitlements = false
    @AppStorage("MacFSW.Inspector.ShowsForensics") private var showsForensics = false
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
                    InspectorHeader(event: event)

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
                    ContentUnavailableView("No Selection", systemImage: "doc.text.magnifyingglass", description: Text("Select an event to see its details."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(Self.scrollTopAnchor)
        }
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

/// What happened and when. The process that did it has its own section.
struct InspectorHeader: View {
    let event: MacFSWFileEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(event.eventType.rawValue.uppercased())
                .font(.callout.weight(.bold))
                .foregroundStyle(color(for: event.eventType))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(color(for: event.eventType).opacity(0.10), in: Capsule())
                .accessibilityLabel("Operation \(event.eventType.rawValue)")

            if let bucket = bucketTitle {
                Text(bucket)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(format(timestampNS: event.timestampNS))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var bucketTitle: String? {
        let title = MacFSWOperationBucket.bucket(for: event.eventType).title
        return title == event.eventType.rawValue.uppercased() ? nil : title
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
