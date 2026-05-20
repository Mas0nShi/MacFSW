import Darwin
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            SidebarPageSwitcher()
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider()

            ProcessFilterPane()
                .frame(maxHeight: .infinity)

            Divider()

            OperationStatsPane()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                SidebarSectionHeader("System Extension")
                SystemExtensionStatusView()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

struct SidebarPageSwitcher: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MacFSWNavigationPage.allCases) { page in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        model.selectedPage = page
                    }
                } label: {
                    SidebarPageSwitcherItem(
                        page: page,
                        isSelected: model.selectedPage == page
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(height: 34)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SidebarPageSwitcherItem: View {
    let page: MacFSWNavigationPage
    let isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: page.symbolName)
                .font(.system(size: 12, weight: .medium))
            Text(page.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            if page.isBeta {
                MacFSWBetaBadge()
            }
        }
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(.easeInOut(duration: 0.14), value: isSelected)
    }

    private var background: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovering {
            return Color.primary.opacity(0.07)
        }
        return .clear
    }
}

struct ProcessFilterPane: View {
    @EnvironmentObject private var model: MacFSWAppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    SidebarSectionHeader("Processes")
                    Spacer()
                    Text("\(model.filteredProcessSummaries.count)")
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

            TextField("Filter process or signing", text: $model.processSearchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)

            Toggle(isOn: $model.includeExitedProcesses) {
                HStack(spacing: 6) {
                    Text("Include Exited")
                    if model.filteredExitedProcessCount > 0 {
                        Text("\(model.filteredExitedProcessCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .padding(.horizontal, 12)

            if model.selectedPage == .monitor, model.selectedProcessID != nil {
                Button {
                    model.clearProcessFilter()
                } label: {
                    Label("Clear Process Filter", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
            }

            if model.filteredProcessGroups.isEmpty {
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
                        ForEach(model.filteredProcessGroups) { group in
                            if group.instanceCount > 1 {
                                Button {
                                    model.toggleProcessGroup(group.id)
                                } label: {
                                    ProcessGroupRow(
                                        group: group,
                                        isExpanded: model.expandedProcessGroupIDs.contains(group.id)
                                    )
                                }
                                .buttonStyle(.plain)

                                if model.expandedProcessGroupIDs.contains(group.id) {
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
            model.selectedProcessID == summary.id
        case .analysis:
            model.selectedAnalysisProcessID == summary.id
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
