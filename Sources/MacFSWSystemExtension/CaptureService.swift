import Foundation
import MacFSWCore

public final class MacFSWEndpointCaptureService: NSObject, MacFSWCaptureXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var activeCapture: EndpointSecurityCapture?
    private var activeSubscriber: MacFSWCaptureEventSubscriber?
    private let encoder = JSONEncoder.macfsw

    public override init() {
        super.init()
    }

    deinit {
        stopActiveCapture(errorMessage: nil)
    }

    public func openCaptureStream(
        _ payload: Data,
        subscriber: MacFSWCaptureEventSubscriber,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        do {
            let request = try JSONDecoder.macfsw.decode(MacFSWCaptureStreamRequest.self, from: payload)

            lock.lock()
            activeCapture?.stop()
            activeSubscriber = subscriber
            lock.unlock()

            let capture = EndpointSecurityCapture(config: request.config) { [weak self] batch in
                self?.send(batch)
            } onFinish: { [weak self] errorMessage in
                self?.stopActiveCapture(errorMessage: errorMessage)
            }

            try capture.start()

            lock.lock()
            activeCapture = capture
            lock.unlock()

            let response = MacFSWCaptureStartResponse(
                accepted: true,
                health: capture.health()
            )
            reply(try encoder.encode(response), nil)
        } catch {
            reply(nil, error.userFacingMessage)
        }
    }

    public func health(withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        lock.lock()
        let activeCapture = activeCapture
        lock.unlock()

        var health = activeCapture?.health() ?? EndpointSecurityCapture.authorizationHealth()
        health.extensionVersion = Bundle.main.macfswComponentVersion

        do {
            reply(try encoder.encode(health), nil)
        } catch {
            reply(nil, error.userFacingMessage)
        }
    }

    private func send(_ batch: MacFSWEventBatch) {
        lock.lock()
        let subscriber = activeSubscriber
        lock.unlock()

        guard let subscriber else {
            stopActiveCapture(errorMessage: "Capture subscriber disconnected.")
            return
        }

        do {
            subscriber.eventBatch(try encoder.encode(batch))
        } catch {
            stopActiveCapture(errorMessage: error.userFacingMessage)
        }
    }

    private func stopActiveCapture(errorMessage: String?) {
        lock.lock()
        let capture = activeCapture
        let subscriber = activeSubscriber
        activeCapture = nil
        activeSubscriber = nil
        lock.unlock()

        capture?.stop()
        subscriber?.captureFinished(errorMessage)
    }
}
