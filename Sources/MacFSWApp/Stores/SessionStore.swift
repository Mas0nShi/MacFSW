import Foundation
import MacFSWCore
import Observation

/// The app's current research session: its metadata, the capture engine
/// behind it, and the recording state the UI shows.
@MainActor
@Observable
final class SessionStore {
    private(set) var research: MacFSWResearchSession
    private(set) var captureState: MacFSWCaptureState = .idle
    var captureHealth = MacFSWCaptureHealth()
    private(set) var captureStats = MacFSWCaptureStats()
    /// Sessions opened from a file are read-only: no recording, no clearing.
    private(set) var isReadOnly = false
    /// The saved file this session was opened from; nil for a recording.
    private(set) var fileURL: URL?
    /// Events were recorded since the session started or was last saved.
    private(set) var hasUnsavedEvents = false

    @ObservationIgnored
    private(set) var capture: MacFSWCaptureSession
    @ObservationIgnored
    private let client: any MacFSWCaptureClient

    /// Newly captured events, already stored and sequenced.
    @ObservationIgnored
    var onEvents: ([MacFSWFileEvent]) -> Void = { _ in }
    /// The capture stream failed after it was opened.
    @ObservationIgnored
    var onCaptureFailure: (any Error) -> Void = { _ in }
    /// Recording ended, by request or because the stream closed.
    @ObservationIgnored
    var onCaptureStopped: () -> Void = {}
    /// Every event was deleted; anything shown so far is gone.
    @ObservationIgnored
    var onCleared: () -> Void = {}
    /// Set while a clear is under way during recording. Batches still in
    /// the update stream ahead of `.cleared` were deleted, so they are
    /// dropped rather than shown.
    @ObservationIgnored
    private var isAwaitingCleared = false

    @ObservationIgnored
    private var updatesTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingStats: MacFSWCaptureStats?
    @ObservationIgnored
    private var statsFlushTask: Task<Void, Never>?

    init(research: MacFSWResearchSession, client: any MacFSWCaptureClient) {
        self.research = research
        self.client = client
        try? MacFSWSQLiteEventStore.cleanupStaleTemporaryStores()
        do {
            capture = try .temporary(for: research, client: client)
        } catch {
            fatalError("MacFSW cannot create its temporary session store: \(error.userFacingMessage)")
        }
    }

    var eventStore: MacFSWSQLiteEventStore {
        capture.store
    }

    var isCaptureActive: Bool {
        captureState == .recording || captureState == .connecting || captureState == .stopping
    }

    func updateResearch(_ update: (inout MacFSWResearchSession) -> Void) {
        update(&research)
        research.metadata.updatedAt = Date()
    }

    func startNew(_ newResearch: MacFSWResearchSession) async throws {
        try await replace(with: .temporary(for: newResearch, client: client), research: newResearch, stats: MacFSWCaptureStats())
        fileURL = nil
    }

    func open(_ url: URL) async throws {
        let (opened, metadata) = try await MacFSWCaptureSession.open(url, client: client)
        try await replace(with: opened, research: metadata, stats: await opened.stats)
        fileURL = url
    }

    func save(to url: URL) async throws {
        try await capture.save(research, to: url)
        hasUnsavedEvents = false
    }

    func clearEvents() async throws {
        let isObserving = updatesTask != nil
        isAwaitingCleared = isObserving
        captureStats = MacFSWCaptureStats()
        pendingStats = nil
        do {
            try await capture.clear()
        } catch {
            isAwaitingCleared = false
            throw error
        }
        hasUnsavedEvents = false
    }

    func refreshHealth() async throws -> MacFSWCaptureHealth {
        let health = try await client.health()
        captureHealth = health
        captureStats = health.stats
        if captureState != .recording {
            captureState = health.state
        }
        return health
    }

    func startCapture() async throws {
        if updatesTask == nil {
            await observe(capture)
        }
        try await capture.start(config: research.captureConfig)
    }

    func stopCapture() async {
        await capture.stop()
    }

    func close() async throws {
        updatesTask?.cancel()
        try await capture.close()
    }

    private func replace(with newCapture: MacFSWCaptureSession, research newResearch: MacFSWResearchSession, stats: MacFSWCaptureStats) async throws {
        let oldCapture = capture
        updatesTask?.cancel()
        updatesTask = nil
        statsFlushTask?.cancel()
        statsFlushTask = nil
        pendingStats = nil
        capture = newCapture
        research = newResearch
        isReadOnly = newCapture.store.isReadOnly
        captureStats = stats
        captureState = .idle
        hasUnsavedEvents = false
        try await oldCapture.close()
    }

    private func observe(_ capture: MacFSWCaptureSession) async {
        let updates = await capture.updates()
        updatesTask = Task { [weak self] in
            for await update in updates {
                self?.handle(update)
            }
        }
    }

    private func handle(_ update: MacFSWCaptureSession.Update) {
        switch update {
        case .appended(let events, let stats):
            guard !isAwaitingCleared else {
                return
            }
            scheduleStatsPublish(stats)
            hasUnsavedEvents = true
            onEvents(events)
        case .stateChanged(let state, let error):
            captureState = state
            switch state {
            case .failed:
                if let error {
                    onCaptureFailure(error)
                }
                onCaptureStopped()
            case .stopped:
                onCaptureStopped()
            default:
                break
            }
        case .cleared(let stats):
            isAwaitingCleared = false
            pendingStats = nil
            captureStats = stats
            hasUnsavedEvents = false
            onCleared()
        }
    }

    /// Capture stats change with every batch; the status bar only needs
    /// them a few times per second.
    private func scheduleStatsPublish(_ stats: MacFSWCaptureStats) {
        pendingStats = stats
        guard statsFlushTask == nil else {
            return
        }
        statsFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled else {
                return
            }
            if let pendingStats {
                captureStats = pendingStats
                self.pendingStats = nil
            }
            statsFlushTask = nil
        }
    }
}
