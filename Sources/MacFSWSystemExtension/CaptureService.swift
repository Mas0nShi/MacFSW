import Foundation
import MacFSWCore

/// One per XPC connection: the capture stream that connection opened.
/// Callbacks into the capture and the subscriber always run outside
/// `lock`, because stopping a capture flushes its last batch through
/// `send`, which takes the lock again.
public final class MacFSWEndpointCaptureService: NSObject, MacFSWCaptureXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var activeCapture: EndpointSecurityCapture?
    private var activeSubscriber: MacFSWCaptureEventSubscriber?
    private let encoder = JSONEncoder.macfsw

    deinit {
        stopActiveCapture()
    }

    public func openCaptureStream(
        _ payload: Data,
        subscriber: MacFSWCaptureEventSubscriber,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        do {
            let request = try JSONDecoder.macfsw.decode(MacFSWCaptureStreamRequest.self, from: payload)
            stopActiveCapture()

            let capture = EndpointSecurityCapture(config: request.config) { [weak self] batch in
                self?.send(batch)
            }
            // Batches can arrive as soon as the capture starts.
            lock.withLock { activeSubscriber = subscriber }
            do {
                try capture.start()
            } catch {
                lock.withLock { activeSubscriber = nil }
                throw error
            }
            lock.withLock { activeCapture = capture }

            let response = MacFSWCaptureStartResponse(accepted: true, health: capture.health())
            reply(try encoder.encode(response), nil)
        } catch {
            reply(nil, error.userFacingMessage)
        }
    }

    public func health(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        var health = lock.withLock { activeCapture }?.health() ?? EndpointSecurityCapture.authorizationHealth()
        health.extensionVersion = Bundle.main.macfswComponentVersion
        do {
            reply(try encoder.encode(health), nil)
        } catch {
            reply(nil, error.userFacingMessage)
        }
    }

    public func stopCaptureStream(withReply reply: @escaping @Sendable () -> Void) {
        stopActiveCapture()
        reply()
    }

    private func send(_ batch: MacFSWEventBatch) {
        guard let subscriber = lock.withLock({ activeSubscriber }) else {
            return
        }
        do {
            subscriber.eventBatch(try encoder.encode(batch))
        } catch {
            stopActiveCapture(errorMessage: error.userFacingMessage)
        }
    }

    /// Stops the capture first so its final batch still reaches the
    /// subscriber, then tells the subscriber the stream ended.
    private func stopActiveCapture(errorMessage: String? = nil) {
        lock.withLock { activeCapture.take() }?.stop()
        lock.withLock { activeSubscriber.take() }?.captureFinished(errorMessage)
    }
}
