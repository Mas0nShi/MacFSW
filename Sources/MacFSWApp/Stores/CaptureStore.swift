import Foundation
import MacFSWCore

@MainActor
final class CaptureStore: ObservableObject {
    @Published var state: MacFSWCaptureState = .idle
    @Published var health = MacFSWCaptureHealth()
    @Published var stats = MacFSWCaptureStats()

    private let client: any MacFSWCaptureClient
    private var handle: MacFSWCaptureHandle?

    init(client: any MacFSWCaptureClient) {
        self.client = client
    }

    var hasActiveStream: Bool {
        handle != nil
    }

    func refreshHealth() async throws -> MacFSWCaptureHealth {
        let health = try await client.health()
        self.health = health
        stats = health.stats
        if state != .recording {
            state = health.state
        }
        return health
    }

    func start(
        config: MacFSWCaptureConfig,
        onBatch: @escaping @MainActor (MacFSWEventBatch) async -> Void,
        onFailure: @escaping @MainActor (Error) -> Void,
        onStopped: @escaping @MainActor () -> Void
    ) {
        guard handle == nil else {
            return
        }
        state = .connecting

        Task { [weak self] in
            do {
                guard let self else { return }
                let handle = try await client.openCaptureStream(
                    config: config,
                    onBatch: { batch in
                        Task { @MainActor in
                            await onBatch(batch)
                        }
                    },
                    onFinish: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.captureDidFinish(
                                error,
                                onFailure: onFailure,
                                onStopped: onStopped
                            )
                        }
                    }
                )

                self.handle = handle
                self.state = .recording
            } catch {
                guard let self else { return }
                self.state = .failed
                onFailure(error)
            }
        }
    }

    func stop() -> Bool {
        guard let handle else {
            state = .idle
            return false
        }
        state = .stopping
        handle.stop()
        self.handle = nil
        state = .stopped
        return true
    }

    private func captureDidFinish(
        _ error: Error?,
        onFailure: @MainActor (Error) -> Void,
        onStopped: @MainActor () -> Void
    ) {
        handle = nil
        if let error {
            if ErrorPresentation.isCancellationError(error) {
                if state == .recording || state == .stopping {
                    state = .stopped
                }
                onStopped()
                return
            }
            state = .failed
            onFailure(error)
        } else if state == .recording || state == .stopping {
            state = .stopped
        }
        if state != .recording {
            onStopped()
        }
    }
}
