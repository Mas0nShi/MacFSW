import AppKit
import MacFSWCore
import UniformTypeIdentifiers

extension MacFSWAppCoordinator {
    // MARK: - Session files

    func newSession() {
        let alert = NSAlert()
        alert.messageText = "Start a New Session?"
        alert.informativeText = "The current session will be closed. Save it first if you want to keep captured events, filters, or analysis results."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "New Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        Task {
            await replaceSession(followMode: .live) {
                try await session.startNew(Self.makeResearchSession(appVersion: environment.appVersion))
            }
        }
    }

    func openSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.sessionContentType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        openSession(at: url)
    }

    /// Opens a saved session from the panel, Finder, the Dock, or a drop.
    func openSession(at url: URL) {
        log.record(.info, "Opening session \(url.lastPathComponent).", category: "Session")
        Task {
            await replaceSession(followMode: .paused) {
                try await session.open(url)
            }
            await refreshProcessSummaries()
            await monitor.refreshFilteredEvents(allowAutoSelection: true)
        }
    }

    func saveSession() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.sessionContentType]
        panel.nameFieldStringValue = "\(session.research.name).\(MacFSWSessionArchive.nativeExtension)"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task {
            do {
                try await session.save(to: url)
            } catch {
                reportError(error)
            }
        }
    }

    /// Clears captured events but keeps the session, its settings, and the
    /// current query.
    func clearView() {
        guard !session.isReadOnly else {
            return
        }
        monitor.cancelAllWork()
        Task {
            do {
                try await session.clearEvents()
                monitor.resetAfterClear()
                resetProcessDerivedState()
                errorMessage = nil
            } catch {
                reportError(error)
            }
        }
    }

    static let sessionContentType = UTType(exportedAs: "com.mas0n.macfsw-session")

    private func replaceSession(followMode: MacFSWFollowMode, _ replace: () async throws -> Void) async {
        monitor.cancelAllWork()
        analysis.cancelTask()
        processSidebar.cancelPublishing()
        do {
            try await replace()
        } catch {
            reportError(error)
            return
        }
        monitor.reset(eventStore: session.eventStore, followMode: followMode)
        resetProcessDerivedState()
        processSidebar.processSearchText = ""
        processSidebar.includeExitedProcesses = preferences.defaultIncludeExitedProcesses
        analysis.resetForNewSession()
        selectedPage = .monitor
        errorMessage = nil
    }

    private func resetProcessDerivedState() {
        processSidebar.clear()
        analysis.resetSelection()
    }

    // MARK: - Capture

    func recordButtonTapped() {
        guard !session.isReadOnly else {
            return
        }
        if session.captureState == .recording {
            stopCapture()
            return
        }
        guard extensionStatus.installState == .ready else {
            if session.captureHealth.fullDiskAccessHint {
                extensionStatus.openFullDiskAccessSettings()
            } else {
                activateSystemExtension()
            }
            return
        }
        startCapture()
    }

    func startCapture() {
        log.record(.info, "Starting capture.", category: "Capture")
        monitor.prepareForLiveCapture()
        errorMessage = nil
        Task {
            do {
                try await session.startCapture()
            } catch {
                handleCaptureFailure(error)
            }
        }
    }

    func stopCapture() {
        log.record(.info, "Stopping capture.", category: "Capture")
        Task { await session.stopCapture() }
    }

    func updateCaptureConfig(_ update: (inout MacFSWCaptureConfig) -> Void) {
        guard !session.isCaptureActive else {
            return
        }
        session.updateResearch { research in
            update(&research.captureConfig)
            research.captureConfig = research.captureConfig.transportSafe
        }
    }

    func ingest(_ events: [MacFSWFileEvent]) {
        processSidebar.update(with: events)
        if let id = monitor.selectedProcessID, !processSidebar.contains(id) {
            monitor.selectedProcessID = nil
        }
        if let id = analysis.selectedProcessID, !processSidebar.contains(id) {
            analysis.selectedProcessID = nil
        }
        monitor.ingest(events)
    }

    func handleCaptureFailure(_ error: any Error) {
        guard !ErrorPresentation.isCancellationError(error) else {
            return
        }
        let message = error.userFacingMessage
        log.record(.error, message, category: "Capture", error: error)
        errorMessage = message

        if ErrorPresentation.isFullDiskAccessError(message) {
            extensionStatus.applyFullDiskAccessFailure(message: message)
            session.captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAuthorized: false,
                fullDiskAccessHint: true,
                message: message
            )
        } else if ErrorPresentation.isXPCConnectionFailure(error) {
            extensionStatus.applyXPCFailure(message: message)
            session.captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAuthorized: false,
                message: message
            )
        }
    }

    // MARK: - System Extension

    func refreshHealth() async {
        do {
            extensionStatus.applyHealth(try await session.refreshHealth())
        } catch {
            guard !ErrorPresentation.isCancellationError(error) else {
                return
            }
            let message = error.userFacingMessage
            extensionStatus.applyHealthRefreshFailure(message: message)
            session.captureHealth = MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAuthorized: false,
                message: message
            )
            reportError(error)
        }
    }

    /// macOS reports an activation done before the new extension process
    /// answers; until it does, the old process may still respond or nothing
    /// may. Waits for the bundled version instead of reporting either as
    /// the outcome.
    func waitForActivatedExtension() async {
        let bundled = extensionStatus.bundledVersion
        for _ in 0..<10 {
            if let health = try? await session.refreshHealth(), bundled == nil || health.extensionVersion == bundled {
                extensionStatus.applyHealth(health)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        await refreshHealth()
    }

    func activateSystemExtension() {
        errorMessage = nil
        extensionStatus.activate()
    }

    func checkSystemExtensionAgain() {
        Task { await refreshHealth() }
    }
}
