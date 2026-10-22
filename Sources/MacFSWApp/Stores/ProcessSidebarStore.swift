import Foundation
import MacFSWCore
import Observation
import SwiftUI

@MainActor
@Observable
final class ProcessSidebarStore {
    var processSearchText = "" {
        didSet {
            schedulePublish(reordering: .immediately)
        }
    }

    private(set) var processSummaries: [MacFSWProcessSummary] = []
    private(set) var filteredProcessSummaries: [MacFSWProcessSummary] = []
    private(set) var filteredProcessGroups: [MacFSWProcessGroupSummary] = []
    var expandedProcessGroupIDs: Set<String> = []
    var includeExitedProcesses: Bool {
        didSet {
            publish(reordering: .immediately)
        }
    }

    @ObservationIgnored
    private var processSummaryIndex: [MacFSWProcessSummary.ID: MacFSWProcessSummary] = [:]
    @ObservationIgnored
    private var publishTask: Task<Void, Never>?
    @ObservationIgnored
    private var reorderTask: Task<Void, Never>?
    @ObservationIgnored
    private var groupOrder = StableRanking<MacFSWProcessGroupSummary.ID>()

    /// Reordering the user asked for (search, filters, a new session) shows
    /// at once; reordering from counts changing while recording is throttled.
    private enum Reordering {
        case immediately
        case throttled
    }

    init(includeExitedProcesses: Bool = true) {
        self.includeExitedProcesses = includeExitedProcesses
    }

    var filteredExitedProcessCount: Int {
        filteredProcessSummaries.filter { $0.lifecycle == .exited }.count
    }

    func update(with events: [MacFSWFileEvent]) {
        ProcessSummaryReducer.update(index: &processSummaryIndex, with: events)
        schedulePublish()
    }

    func replace(with summaries: [MacFSWProcessSummary]) {
        processSummaryIndex = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.lastEventNS >= rhs.lastEventNS ? lhs : rhs
        })
        publish(reordering: .immediately)
    }

    func clear() {
        cancelPublishing()
        groupOrder = StableRanking()
        processSummaryIndex.removeAll(keepingCapacity: true)
        processSummaries = []
        filteredProcessSummaries = []
        filteredProcessGroups = []
        expandedProcessGroupIDs.removeAll(keepingCapacity: true)
    }

    func cancelPublishing() {
        publishTask?.cancel()
        publishTask = nil
        reorderTask?.cancel()
        reorderTask = nil
    }

    func summary(for id: MacFSWProcessSummary.ID) -> MacFSWProcessSummary? {
        processSummaryIndex[id] ?? processSummaries.first { $0.id == id }
    }

    func contains(_ id: MacFSWProcessSummary.ID) -> Bool {
        summary(for: id) != nil
    }

    private func schedulePublish(reordering: Reordering = .throttled) {
        if reordering == .immediately {
            publishTask?.cancel()
            publishTask = nil
        }
        guard publishTask == nil else {
            return
        }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else {
                return
            }
            self?.publish(reordering: reordering)
        }
    }

    private func publish(reordering: Reordering = .throttled) {
        publishTask?.cancel()
        publishTask = nil
        reorderTask?.cancel()
        reorderTask = nil
        let summaries = ProcessSummaryReducer.summaries(from: processSummaryIndex)
        processSummaries = summaries
        let filtered = ProcessSummaryReducer.filteredSummaries(
            summaries,
            query: processSearchText,
            includeExited: includeExitedProcesses
        )
        filteredProcessSummaries = filtered

        let ranked = ProcessSummaryReducer.groups(from: filtered)
        if reordering == .immediately {
            groupOrder = StableRanking()
        }
        let update = groupOrder.update(ranked.map { ($0.id, $0.eventCount) })
        let byID = Dictionary(uniqueKeysWithValues: ranked.map { ($0.id, $0) })
        let groups = update.order.compactMap { byID[$0] }
        if update.moved {
            withAnimation(.easeInOut(duration: 0.25)) {
                filteredProcessGroups = groups
            }
        } else {
            filteredProcessGroups = groups
        }
        if let retryAfter = update.retryAfter {
            reorderTask = Task { [weak self] in
                try? await Task.sleep(for: retryAfter)
                guard !Task.isCancelled else {
                    return
                }
                self?.publish()
            }
        }
    }

    func toggleProcessGroup(_ id: String) {
        if expandedProcessGroupIDs.contains(id) {
            expandedProcessGroupIDs.remove(id)
        } else {
            expandedProcessGroupIDs.insert(id)
        }
    }
}
