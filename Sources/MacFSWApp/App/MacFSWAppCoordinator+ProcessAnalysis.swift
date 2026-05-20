import AppKit
import Combine
import Darwin
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import UniformTypeIdentifiers

extension MacFSWAppCoordinator {
    func refreshProcessSummariesFromStore() async {
        do {
            let summaries = try await eventStore.processSummaries()
                .map(MacFSWProcessSummary.init(coreSummary:))
                .sortedForDisplay()
            replaceProcessSummaries(summaries)
        } catch {
            reportError(error)
        }
    }

    func updateProcessSummaries(with events: [MacFSWFileEvent]) {
        guard !events.isEmpty else {
            return
        }

        processSidebarStore.update(with: events)
        if let selectedProcessID, !processSidebarStore.contains(selectedProcessID) {
            self.selectedProcessID = nil
        }
        if let selectedAnalysisProcessID, !processSidebarStore.contains(selectedAnalysisProcessID) {
            self.selectedAnalysisProcessID = nil
        }
    }

    func replaceProcessSummaries(_ summaries: [MacFSWProcessSummary]) {
        processSidebarStore.replace(with: summaries)
    }

    func clearProcessSummaries() {
        processSidebarStore.clear()
        selectedAnalysisProcessID = nil
    }

    static func lifecycle(for pid: Int32) -> MacFSWProcessLifecycle {
        ProcessSummaryReducer.lifecycle(for: pid)
    }

    func processGroups(from summaries: [MacFSWProcessSummary]) -> [MacFSWProcessGroupSummary] {
        ProcessSummaryReducer.groups(from: summaries)
    }

    func filteredProcessSummaries(from summaries: [MacFSWProcessSummary]) -> [MacFSWProcessSummary] {
        ProcessSummaryReducer.filteredSummaries(
            summaries,
            query: processSearchText,
            includeExited: includeExitedProcesses
        )
    }

    func filterProcessSummaries(
        _ summaries: [MacFSWProcessSummary],
        query rawQuery: String,
        includeExited: Bool
    ) -> [MacFSWProcessSummary] {
        ProcessSummaryReducer.filteredSummaries(summaries, query: rawQuery, includeExited: includeExited)
    }

    func operationSummaries(from summaries: [MacFSWOperationEventSummary]) -> [MacFSWOperationSummary] {
        OperationSummaryReducer.operationSummaries(from: summaries)
    }

    func applyOperationSummaryDelta(from rows: [MacFSWEventRowSummary]) {
        operationSummaries = OperationSummaryReducer.applying(rows: rows, to: operationSummaries)
    }

    func sortedOperationSummaries(from counts: [MacFSWOperationBucket: Int]) -> [MacFSWOperationSummary] {
        OperationSummaryReducer.sortedOperationSummaries(from: counts)
    }

    func scheduleQueryRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else {
                return
            }
            await self?.refreshFilteredEvents()
        }
    }

    func refreshFilteredEvents(allowAutoSelection: Bool = false) async {
        await refreshFilteredEvents(using: nil, allowAutoSelection: allowAutoSelection)
    }

    func applySavedQuery(_ saved: MacFSWSavedQuery) {
        queryText = saved.query.text
        Task {
            var query = saved.query
            query.limit = 0
            await refreshFilteredEvents(using: query, allowAutoSelection: true)
        }
    }

    func applyProcessFilter(_ summary: MacFSWProcessSummary) {
        selectedProcessID = summary.id
        selectedPage = .monitor
        clearEventSelection()
        Task {
            await refreshFilteredEvents()
        }
    }

    func clearProcessFilter() {
        selectedProcessID = nil
        clearEventSelection()
        Task {
            await refreshFilteredEvents()
        }
    }

    func toggleProcessGroup(_ id: String) {
        if expandedProcessGroupIDs.contains(id) {
            expandedProcessGroupIDs.remove(id)
        } else {
            expandedProcessGroupIDs.insert(id)
        }
    }

    func selectAnalysisProcess(_ summary: MacFSWProcessSummary) {
        analysisStore.selectProcess(summary)
        selectedPage = .analysis
    }

    func selectSidebarProcess(_ summary: MacFSWProcessSummary) {
        switch selectedPage {
        case .monitor:
            applyProcessFilter(summary)
        case .analysis:
            selectAnalysisProcess(summary)
        }
    }

    func runAnalysis() {
        selectedPage = .analysis
        analysisStore.runAnalysis(
            target: selectedAnalysisProcess,
            eventStore: eventStore,
            settings: llmSettings,
            reportError: { [weak self] error in
                self?.reportError(error)
            }
        )
    }

    func cancelAnalysis() {
        analysisStore.cancelAnalysis()
    }

    func clearAnalysisHistory() {
        analysisStore.clearHistory()
    }

    func testLLMConnection() {
        analysisStore.testConnection(settings: llmSettings)
    }

    var captureSettingsLocked: Bool {
        captureState == .recording || captureState == .connecting || captureState == .stopping
    }

    func updateCaptureProfile(_ profile: MacFSWCaptureProfile) {
        updateCaptureConfig { config in
            config.profile = profile
            config.eventTypes = MacFSWCaptureConfig.defaultEventTypes(for: profile)
        }
    }

    func updateCaptureBatchSize(_ value: Int) {
        updateCaptureConfig { config in
            config.batchSize = max(1, value)
        }
    }

    func updateCaptureBatchInterval(_ value: Int) {
        updateCaptureConfig { config in
            config.batchIntervalMS = max(10, value)
        }
    }

    func updateCaptureDuration(_ value: Int) {
        updateCaptureConfig { config in
            config.maxCaptureDurationSeconds = max(5, value)
        }
    }

    func updateExcludedProcesses(_ text: String) {
        updateCaptureConfig { config in
            config.excludedProcessNames = Self.lines(from: text)
        }
    }

    func updateExcludePaths(_ text: String) {
        updateCaptureConfig { config in
            config.excludePaths = Self.lines(from: text)
        }
    }

    func updateCaptureConfig(_ update: (inout MacFSWCaptureConfig) -> Void) {
        guard !captureSettingsLocked else {
            return
        }
        sessionStore.updateSession { session in
            var config = session.captureConfig
            update(&config)
            session.captureConfig = config.transportSafe
        }
    }

    static func lines(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func selectAnalysis(_ result: MacFSWAnalysisResult) {
        analysisStore.selectAnalysis(result)
        selectedPage = .analysis
    }
}
