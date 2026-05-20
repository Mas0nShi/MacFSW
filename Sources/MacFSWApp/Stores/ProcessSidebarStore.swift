import Foundation
import MacFSWCore

@MainActor
final class ProcessSidebarStore: ObservableObject {
    @Published var processSearchText = "" {
        didSet {
            schedulePublish()
        }
    }

    @Published private(set) var processSummaries: [MacFSWProcessSummary] = []
    @Published private(set) var filteredProcessSummaries: [MacFSWProcessSummary] = []
    @Published private(set) var filteredProcessGroups: [MacFSWProcessGroupSummary] = []
    @Published var expandedProcessGroupIDs: Set<String> = []
    @Published var includeExitedProcesses: Bool {
        didSet {
            publish()
        }
    }

    private var processSummaryIndex: [MacFSWProcessSummary.ID: MacFSWProcessSummary] = [:]
    private var publishTask: Task<Void, Never>?

    init(includeExitedProcesses: Bool = true) {
        self.includeExitedProcesses = includeExitedProcesses
    }

    var filteredExitedProcessCount: Int {
        filteredProcessSummaries.filter { $0.lifecycle == .exited }.count
    }

    func update(with events: [MacFSWFileEvent]) {
        guard !events.isEmpty else {
            return
        }
        ProcessSummaryReducer.update(index: &processSummaryIndex, with: events)
        schedulePublish()
    }

    func replace(with summaries: [MacFSWProcessSummary]) {
        processSummaryIndex = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.lastEventNS >= rhs.lastEventNS ? lhs : rhs
        })
        publish()
    }

    func clear() {
        publishTask?.cancel()
        publishTask = nil
        processSummaryIndex.removeAll(keepingCapacity: true)
        processSummaries = []
        filteredProcessSummaries = []
        filteredProcessGroups = []
        expandedProcessGroupIDs.removeAll(keepingCapacity: true)
    }

    func cancelPublishing() {
        publishTask?.cancel()
        publishTask = nil
    }

    func summary(for id: MacFSWProcessSummary.ID) -> MacFSWProcessSummary? {
        processSummaryIndex[id] ?? processSummaries.first { $0.id == id }
    }

    func contains(_ id: MacFSWProcessSummary.ID) -> Bool {
        summary(for: id) != nil
    }

    private func schedulePublish() {
        guard publishTask == nil else {
            return
        }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.publishTask = nil
                self?.publish()
            }
        }
    }

    private func publish() {
        publishTask?.cancel()
        publishTask = nil
        let summaries = ProcessSummaryReducer.summaries(from: processSummaryIndex)
        processSummaries = summaries
        let filtered = ProcessSummaryReducer.filteredSummaries(
            summaries,
            query: processSearchText,
            includeExited: includeExitedProcesses
        )
        filteredProcessSummaries = filtered
        filteredProcessGroups = ProcessSummaryReducer.groups(from: filtered)
    }
}
