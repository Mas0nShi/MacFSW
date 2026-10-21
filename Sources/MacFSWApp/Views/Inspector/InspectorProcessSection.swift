import MacFSWCore
import SwiftUI

struct InspectorProcessSection: View {
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

struct InspectorEntitlementRow: View {
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
