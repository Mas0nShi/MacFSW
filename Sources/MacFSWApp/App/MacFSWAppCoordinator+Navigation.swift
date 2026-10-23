import MacFSWAnalysis
import MacFSWCore

extension MacFSWAppCoordinator {
    /// A sidebar click filters the Monitor or targets Analysis, depending on
    /// which page is showing.
    func selectSidebarProcess(_ summary: MacFSWProcessSummary) {
        switch selectedPage {
        case .monitor:
            applyProcessFilter(summary)
        case .analysis:
            analysis.selectProcess(summary)
        }
    }

    func applyProcessFilter(_ summary: MacFSWProcessSummary) {
        selectedPage = .monitor
        monitor.pinProcess(summary.pid)
    }

    func refreshProcessSummaries() async {
        do {
            let summaries = try await session.eventStore.processSummaries()
                .map(MacFSWProcessSummary.init(coreSummary:))
                .sortedForDisplay()
            processSidebar.replace(with: summaries)
        } catch {
            reportError(error)
        }
    }

    // MARK: - Analysis

    func runAnalysis() {
        selectedPage = .analysis
        analysis.runAnalysis(
            target: selectedAnalysisProcess,
            eventStore: session.eventStore,
            settings: preferences.resolvedLLMSettings,
            template: analysisTemplates.selectedTemplate,
            reportError: { [weak self] error in
                self?.reportError(error)
            }
        )
    }

    func selectAnalysis(_ result: MacFSWAnalysisResult) {
        analysis.selectAnalysis(result)
        selectedPage = .analysis
    }

    func testLLMConnection() {
        analysis.testConnection(settings: preferences.resolvedLLMSettings)
    }
}
