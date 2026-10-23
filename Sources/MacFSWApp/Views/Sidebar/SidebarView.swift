import Darwin
import SwiftUI

struct SidebarView: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ProcessFilterPane()
                .frame(maxHeight: .infinity)

            Divider()

            OperationStatsPane()

            // Ready is the normal state and lives in the status bar; the
            // card appears only when the extension needs the user.
            if extensionNeedsAttention {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    SidebarSectionHeader("System Extension")
                    SystemExtensionStatusView()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: extensionNeedsAttention)
        .background(.bar)
    }
}

private extension SidebarView {
    var extensionNeedsAttention: Bool {
        let status = model.extensionStatus
        return status.installState != .ready
            || status.isRunningOutdatedExtension
            || status.completedUpdate != nil
            || model.session.captureHealth.fullDiskAccessHint
    }
}

struct ProcessFilterPane: View {
    @Environment(MacFSWAppCoordinator.self) private var model

    var body: some View {
        @Bindable var processSidebar = model.processSidebar
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    SidebarSectionHeader("Processes")
                    Spacer()
                    Text("\(model.processSidebar.filteredProcessSummaries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(processActionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            TextField("Find in process list", text: $processSidebar.processSearchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)

            Toggle(isOn: $processSidebar.includeExitedProcesses) {
                HStack(spacing: 6) {
                    Text("Include Exited")
                    if model.processSidebar.filteredExitedProcessCount > 0 {
                        Text("\(model.processSidebar.filteredExitedProcessCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .padding(.horizontal, 12)

            if model.selectedPage == .monitor, model.monitor.pinnedPID != nil {
                Button {
                    model.monitor.pinProcess(nil)
                } label: {
                    Label("Clear Process Filter", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
            }

            if model.processSidebar.filteredProcessGroups.isEmpty {
                Text("No process events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.processSidebar.filteredProcessGroups) { group in
                            if group.instanceCount > 1 {
                                Button {
                                    model.processSidebar.toggleProcessGroup(group.id)
                                } label: {
                                    ProcessGroupRow(
                                        group: group,
                                        isExpanded: model.processSidebar.expandedProcessGroupIDs.contains(group.id)
                                    )
                                }
                                .buttonStyle(.plain)

                                if model.processSidebar.expandedProcessGroupIDs.contains(group.id) {
                                    ForEach(group.summaries) { summary in
                                        Button {
                                            model.selectSidebarProcess(summary)
                                        } label: {
                                            ProcessSummaryRow(
                                                summary: summary,
                                                isSelected: isSelected(summary)
                                            )
                                            .padding(.leading, 14)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } else if let summary = group.summaries.first {
                                Button {
                                    model.selectSidebarProcess(summary)
                                } label: {
                                    ProcessSummaryRow(summary: summary, isSelected: isSelected(summary))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var processActionHint: String {
        switch model.selectedPage {
        case .monitor:
            "Click to filter events"
        case .analysis:
            "Click to select target"
        }
    }

    private func isSelected(_ summary: MacFSWProcessSummary) -> Bool {
        switch model.selectedPage {
        case .monitor:
            model.monitor.pinnedPID == summary.pid
        case .analysis:
            model.analysis.selectedProcessID == summary.id
        }
    }
}

struct ProcessGroupRow: View {
    let group: MacFSWProcessGroupSummary
    let isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            ProcessIconView(group: group)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.processName)
                    .lineLimit(1)
                Text(groupSubtitle)
                    .font(.caption)
                    .foregroundStyle(group.exitedCount > 0 ? .orange : .secondary)
            }
            Spacer()
            Text("\(group.eventCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(.easeInOut(duration: 0.14), value: isExpanded)
    }

    private var groupSubtitle: String {
        if group.exitedCount > 0 {
            return "\(group.instanceCount) processes, \(group.exitedCount) exited"
        }
        return "\(group.instanceCount) processes"
    }
}
