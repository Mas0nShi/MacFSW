import AppKit
import Combine
import Darwin
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import UniformTypeIdentifiers

extension MacFSWAppCoordinator {
    func newSession() {
        guard confirmSessionReplacement(
            title: "Start a New Session?",
            message: "The current session will be closed. Save it first if you want to keep captured events, filters, or analysis results."
        ) else {
            return
        }
        stopCapture()
        renderTask?.cancel()
        renderTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        filterTask?.cancel()
        filterTask = nil
        analysisStore.cancelTask()
        processSidebarStore.cancelPublishing()
        cancelSelectedEventLoad()
        cancelSnapshotCleanup()
        cancelRowLoads()
        Task {
            do {
                let newSession = MacFSWResearchSession(
                    name: "Untitled Research Session",
                    targetDescription: "Focused file-system mutation capture",
                    metadata: makeSessionMetadata()
                )
                let newStore = try sessionStore.makeTemporaryStore(for: newSession)
                let oldStore = await MainActor.run { () -> MacFSWSQLiteEventStore in
                    let oldStore = sessionStore.replace(session: newSession, eventStore: newStore)
                    visibleEventCount = 0
                    totalMatchingEventCount = 0
                    resetRowCache(resetTable: true)
                    selectedEventID = nil
                    selectedRow = nil
                    selectedEvent = nil
                    selectedEventIsLoading = false
                    isApplyingFilter = false
                    queryText = ""
                    activeQuery = MacFSWEventQuery()
                    activeSnapshot = nil
                    processSearchText = ""
                    includeExitedProcesses = defaultIncludeExitedProcesses
                    operationSummaries = []
                    clearProcessSummaries()
                    selectedProcessID = nil
                    analysisStore.resetForNewSession()
                    selectedPage = .monitor
                    followMode = .live
                    unseenEventCount = 0
                    isViewingLiveEdge = true
                    scrollToLiveSerial += 1
                    selectionResetSerial += 1
                    errorMessage = nil
                    lastUpdatedAt = Date()
                    return oldStore
                }
                await cleanupStoreIfOwned(oldStore)
            } catch {
                await MainActor.run {
                    reportError(error)
                }
            }
        }
    }

    func confirmSessionReplacement(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "New Session")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func refreshHealth() async {
        do {
            let health = try await captureStore.refreshHealth()
            systemExtensionStatusStore.applyHealth(health)
        } catch {
            guard !isCancellationError(error) else {
                return
            }
            systemExtensionStatusStore.applyHealthRefreshFailure(message: userFacingMessage(error))
            captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAvailable: true,
                endpointSecurityAuthorized: false,
                message: userFacingMessage(error)
            )
            reportError(error)
        }
    }

    func recordButtonTapped() {
        if captureState == .recording {
            stopCapture()
            return
        }

        guard extensionInstallState == .ready else {
            if captureHealth.fullDiskAccessHint {
                openFullDiskAccessSettings()
                return
            }
            activateSystemExtension()
            return
        }

        startCapture()
    }

    func activateSystemExtension() {
        errorMessage = nil
        systemExtensionStatusStore.activate()
    }

    func openSystemExtensionSettings() {
        systemExtensionStatusStore.openLoginItemsSettings()
    }

    func openFullDiskAccessSettings() {
        systemExtensionStatusStore.openFullDiskAccessSettings()
    }

    func checkSystemExtensionAgain() {
        systemExtensionStatusStore.checkAgain()
        Task {
            await refreshHealth()
        }
    }

    func startCapture() {
        guard !captureStore.hasActiveStream else {
            return
        }
        logStore.record(.info, "Starting capture.", category: "Capture")
        followMode = .live
        unseenEventCount = 0
        isViewingLiveEdge = true
        scrollToLiveSerial += 1
        errorMessage = nil

        captureStore.start(
            config: session.captureConfig,
            onBatch: { [weak self] batch in
                await self?.ingest(batch)
            },
            onFailure: { [weak self] error in
                self?.handleCaptureStartFailure(error)
            },
            onStopped: { [weak self] in
                self?.captureStopped()
            }
        )
    }

    func stopCapture() {
        guard captureStore.stop() else {
            return
        }
        logStore.record(.info, "Stopping capture.", category: "Capture")
        captureStopped()
        pendingCaptureStats = nil
    }

    func clearView() {
        renderTask?.cancel()
        renderTask = nil
        filterTask?.cancel()
        filterTask = nil
        cancelSelectedEventLoad()
        cancelSnapshotCleanup()
        cancelRowLoads()
        Task {
            do {
                try await eventStore.clear()
                await MainActor.run {
                    visibleEventCount = 0
                    totalMatchingEventCount = 0
                    resetRowCache(resetTable: true)
                    selectedEventID = nil
                    selectedRow = nil
                    selectedEvent = nil
                    selectedEventIsLoading = false
                    isApplyingFilter = false
                    activeQuery = MacFSWQueryParser.parse(queryText)
                    activeSnapshot = nil
                    operationSummaries = []
                    clearProcessSummaries()
                    selectedProcessID = nil
                    selectedAnalysisProcessID = nil
                    streamingAnalysisMarkdown = ""
                    analysisStatusText = "Select a process to analyze."
                    analysisRunError = nil
                    followMode = .live
                    unseenEventCount = 0
                    isViewingLiveEdge = true
                    scrollToLiveSerial += 1
                    selectionResetSerial += 1
                    errorMessage = nil
                    lastUpdatedAt = Date()
                }
            } catch {
                await MainActor.run {
                    reportError(error)
                }
            }
        }
    }

    func resetVisibleStateForLoadedStore() {
        filterTask?.cancel()
        filterTask = nil
        cancelAnalysis()
        cancelSelectedEventLoad()
        cancelSnapshotCleanup()
        visibleEventCount = 0
        totalMatchingEventCount = 0
        resetRowCache(resetTable: true)
        selectedEventID = nil
        selectedRow = nil
        selectedEvent = nil
        selectedEventIsLoading = false
        isApplyingFilter = false
        activeQuery = MacFSWEventQuery()
        activeSnapshot = nil
        processSearchText = ""
        includeExitedProcesses = defaultIncludeExitedProcesses
        operationSummaries = []
        clearProcessSummaries()
        selectedProcessID = nil
        selectedAnalysisProcessID = nil
        streamingAnalysisMarkdown = ""
        analysisStatusText = "Select a process to analyze."
        analysisRunError = nil
        selectedPage = .monitor
        followMode = .paused
        unseenEventCount = 0
        isViewingLiveEdge = true
        selectionResetSerial += 1
        captureState = .idle
    }
}
