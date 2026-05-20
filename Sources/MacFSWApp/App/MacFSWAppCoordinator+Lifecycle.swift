import AppKit
import Combine
import Darwin
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import UniformTypeIdentifiers

extension MacFSWAppCoordinator {

    func observeStores() {
        preferencesStore.onError = { [weak self] error in
            self?.reportError(error)
        }
        preferencesStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
        processSidebarStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
        systemExtensionStatusStore.onErrorMessage = { [weak self] message in
            self?.errorMessage = message
            self?.logStore.record(.error, message, category: "SystemExtension")
        }
        systemExtensionStatusStore.onReady = { [weak self] in
            Task { [weak self] in
                await self?.refreshHealth()
            }
        }
        systemExtensionStatusStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
        analysisStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
        sessionStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
        captureStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
        monitorStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
        logStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &storeCancellables)
    }

    func cleanupStoreIfOwned(_ store: MacFSWSQLiteEventStore) async {
        do {
            try await sessionStore.cleanupStoreIfOwned(store)
        } catch {
            reportError(error)
        }
    }

    func prepareForTermination() async {
        stopCapture()
        renderTask?.cancel()
        refreshTask?.cancel()
        filterTask?.cancel()
        analysisStore.cancelTask()
        processSidebarStore.cancelPublishing()
        cancelSelectedEventLoad()
        cancelSnapshotCleanup()
        cancelRowLoads()
        await cleanupStoreIfOwned(eventStore)
    }

    var statusText: String {
        switch captureState {
        case .recording:
            "Recording"
        case .connecting:
            "Connecting"
        case .stopping:
            "Stopping"
        case .failed:
            "Failed"
        case .degraded:
            "Degraded"
        case .stopped:
            "Stopped"
        case .idle:
            "Idle"
        }
    }

    var captureStatusDetail: String {
        switch captureState {
        case .recording:
            followMode == .live ? "Following live events." : "View is paused; capture is still running."
        case .connecting:
            "Opening Endpoint Security stream."
        case .stopping:
            "Stopping capture stream."
        case .failed, .degraded:
            captureHealth.message
        case .stopped, .idle:
            captureStats.deliveredEvents > 0
                ? "\(captureStats.deliveredEvents) events captured."
                : "Capture service is idle."
        }
    }

    var shouldShowJumpToLive: Bool {
        captureState == .recording && ((followMode != .live && unseenEventCount > 0) || !isViewingLiveEdge)
    }

    var jumpToLiveTitle: String {
        "Jump to Live"
    }

    var shouldShowInspector: Bool {
        selectedEventID != nil || selectedEvent != nil || selectedEventIsLoading
    }

    var filteredExitedProcessCount: Int {
        processSidebarStore.filteredExitedProcessCount
    }

    var selectedAnalysis: MacFSWAnalysisResult? {
        analysisStore.selectedAnalysis
    }

    var selectedAnalysisProcess: MacFSWProcessSummary? {
        guard let selectedAnalysisProcessID else {
            return nil
        }
        return processSummary(for: selectedAnalysisProcessID)
    }

    var canRunAnalysis: Bool {
        selectedAnalysisProcess != nil && !isAnalysisRunning
    }

    var isTestingLLMConnection: Bool {
        analysisStore.isTestingConnection
    }
}
