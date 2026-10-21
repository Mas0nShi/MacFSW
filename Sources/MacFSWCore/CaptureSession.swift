import Foundation

/// One research session's event store plus the capture stream feeding it.
///
/// This is the UI-independent engine shared by the app and the `macfsw`
/// CLI: it owns recording state, appends batches to the store strictly in
/// delivery order, and fans out what changed to any number of observers.
/// Session metadata (`MacFSWResearchSession`) stays with the caller; the
/// engine only needs the capture config to start and the metadata to save.
public enum MacFSWCaptureSessionError: Error, LocalizedError, Equatable, Sendable {
    case readOnly

    public var errorDescription: String? {
        "This session was opened from a file and is read-only. Start a new session to record."
    }
}

public actor MacFSWCaptureSession {
    public enum Update: Sendable {
        /// Events were appended to the store, already sequenced.
        case appended(events: [MacFSWFileEvent], stats: MacFSWCaptureStats)
        /// Recording state changed; `error` is set when capture failed.
        case stateChanged(MacFSWCaptureState, error: (any Error)?)
    }

    public nonisolated let store: MacFSWSQLiteEventStore
    public private(set) var state: MacFSWCaptureState = .idle
    public private(set) var stats: MacFSWCaptureStats

    private let client: any MacFSWCaptureClient
    private var handle: MacFSWCaptureHandle?
    private var ingestTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<Update>.Continuation] = [:]

    private enum Incoming: Sendable {
        case batch(MacFSWEventBatch)
        case finished((any Error)?)
    }

    public init(store: MacFSWSQLiteEventStore, client: any MacFSWCaptureClient, stats: MacFSWCaptureStats = MacFSWCaptureStats()) {
        self.store = store
        self.client = client
        self.stats = stats
    }

    /// A new session backed by a temporary store that is deleted on `close()`.
    public static func temporary(
        for session: MacFSWResearchSession,
        client: any MacFSWCaptureClient
    ) throws -> MacFSWCaptureSession {
        MacFSWCaptureSession(store: try .temporary(session: session), client: client)
    }

    /// Opens a saved `.macfsw-session` file and returns it with its metadata.
    public static func open(
        _ url: URL,
        client: any MacFSWCaptureClient
    ) async throws -> (MacFSWCaptureSession, MacFSWResearchSession) {
        let store = try MacFSWSessionArchive.openSessionStore(from: url)
        let metadata = try await store.sessionMetadata()
        let stats = try await store.stats()
        return (MacFSWCaptureSession(store: store, client: client, stats: stats), metadata)
    }

    public var isRecording: Bool {
        handle != nil
    }

    /// Observes appends and state changes from now on. Each call returns an
    /// independent stream; it ends when the observer stops iterating or the
    /// session closes.
    public func updates() -> AsyncStream<Update> {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    /// Opens the capture stream and returns once the System Extension has
    /// accepted it. Throws if the stream cannot be opened. Recording stops
    /// on its own after `config.maxCaptureDurationSeconds`.
    public func start(config: MacFSWCaptureConfig) async throws {
        guard !store.isReadOnly else {
            throw MacFSWCaptureSessionError.readOnly
        }
        guard state != .connecting, handle == nil else {
            return
        }
        setState(.connecting)

        let (incoming, sink) = AsyncStream<Incoming>.makeStream()
        let opened: MacFSWCaptureHandle
        do {
            // XPC delivers both callbacks on one serial queue, so yielding
            // into a single stream preserves batch order — and the finish
            // signal can never overtake the last batch.
            opened = try await client.openCaptureStream(
                config: config.transportSafe,
                onBatch: { sink.yield(.batch($0)) },
                onFinish: { sink.yield(.finished($0)) }
            )
        } catch {
            sink.finish()
            setState(.failed, error: error)
            throw error
        }

        guard state == .connecting else {
            // `stop()` ran while the stream was still opening.
            opened.stop()
            sink.finish()
            return
        }
        handle = opened
        setState(.recording)
        ingestTask = Task { await self.ingest(incoming) }
        let duration = Duration.seconds(config.maxCaptureDurationSeconds)
        deadlineTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else {
                return
            }
            self.stop()
        }
    }

    public func stop() {
        switch state {
        case .connecting:
            setState(.stopped)
        case .recording:
            deadlineTask?.cancel()
            deadlineTask = nil
            handle?.stop()
            handle = nil
            setState(.stopped)
        default:
            break
        }
    }

    public func save(_ session: MacFSWResearchSession, to url: URL) async throws {
        try await MacFSWSessionArchive.saveSession(session, from: store, to: url)
    }

    /// Stops capture, ends all observer streams, and deletes the backing
    /// store if it is temporary. The session is unusable afterwards.
    public func close() async throws {
        stop()
        ingestTask?.cancel()
        for continuation in observers.values {
            continuation.finish()
        }
        observers.removeAll()
        try await store.cleanupBackingStore()
    }

    /// Deletes every event; the session stays usable.
    public func clear() async throws {
        guard !store.isReadOnly else {
            throw MacFSWCaptureSessionError.readOnly
        }
        try await store.clear()
        stats = MacFSWCaptureStats()
    }

    private func ingest(_ incoming: AsyncStream<Incoming>) async {
        for await item in incoming {
            switch item {
            case .batch(let batch):
                do {
                    let result = try await store.appendReturningEvents(batch.events)
                    stats = batch.stats
                    stats.deliveredEvents = result.stats.deliveredEvents
                    publish(.appended(events: result.events, stats: stats))
                } catch {
                    finishCapture(error: error)
                    return
                }
            case .finished(let error):
                finishCapture(error: error)
                return
            }
        }
    }

    private func finishCapture(error: (any Error)?) {
        deadlineTask?.cancel()
        deadlineTask = nil
        handle?.stop()
        handle = nil
        ingestTask = nil
        guard state == .recording else {
            return
        }
        if let error, !(error is CancellationError) {
            setState(.failed, error: error)
        } else {
            setState(.stopped)
        }
    }

    private func setState(_ newState: MacFSWCaptureState, error: (any Error)? = nil) {
        state = newState
        publish(.stateChanged(newState, error: error))
    }

    private func publish(_ update: Update) {
        for continuation in observers.values {
            continuation.yield(update)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
