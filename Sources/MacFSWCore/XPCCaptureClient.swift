import Foundation

public enum MacFSWXPCDefaults {
    public static let serviceName = "UYF535Y9QZ.com.mas0n.MacFSW.EndpointExtension.xpc"
}

public final class MacFSWXPCCaptureClient: MacFSWCaptureClient, @unchecked Sendable {
    private let serviceName: String
    private let healthTimeoutSeconds: UInt64
    private let encoder = JSONEncoder.macfsw
    private let decoder = JSONDecoder.macfsw

    public init(serviceName: String = MacFSWXPCDefaults.serviceName, healthTimeoutSeconds: UInt64 = 8) {
        self.serviceName = serviceName
        self.healthTimeoutSeconds = max(1, healthTimeoutSeconds)
    }

    public func health() async throws -> MacFSWCaptureHealth {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: serviceName, options: [])
            connection.remoteObjectInterface = MacFSWXPCInterfaces.captureServiceInterface()
            let state = XPCRequestState(connection: connection, continuation: continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                state.finish(.failure(error))
            } as? MacFSWCaptureXPCProtocol

            guard let proxy else {
                state.finish(.failure(MacFSWClientError.xpcUnavailable("Unable to create XPC proxy.")))
                return
            }

            connection.resume()
            Task {
                try? await Task.sleep(nanoseconds: healthTimeoutSeconds * 1_000_000_000)
                state.finish(.failure(MacFSWClientError.xpcUnavailable("Health check timed out.")))
            }
            proxy.health { data, errorMessage in
                state.finish(self.decodeResult(data: data, errorMessage: errorMessage, as: MacFSWCaptureHealth.self))
            }
        }
    }

    public func openCaptureStream(
        config: MacFSWCaptureConfig,
        onBatch: @escaping @Sendable (MacFSWEventBatch) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> MacFSWCaptureHandle {
        let connection = NSXPCConnection(machServiceName: serviceName, options: [])
        let connectionBox = XPCConnectionBox(connection)
        let receiver = XPCEventReceiver(onBatch: onBatch, onFinish: onFinish)
        connection.remoteObjectInterface = MacFSWXPCInterfaces.captureServiceInterface()
        connection.exportedInterface = MacFSWXPCInterfaces.captureEventSubscriberInterface()
        connection.exportedObject = receiver

        return try await withCheckedThrowingContinuation { continuation in
            let state = XPCRequestState(connection: connection, continuation: continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                onFinish(error)
                state.finish(.failure(error))
            } as? MacFSWCaptureXPCProtocol

            guard let proxy else {
                state.finish(.failure(MacFSWClientError.xpcUnavailable("Unable to create XPC proxy.")))
                return
            }

            do {
                let payload = try encoder.encode(MacFSWCaptureStreamRequest(config: config.transportSafe))
                connection.interruptionHandler = {
                    onFinish(MacFSWClientError.xpcUnavailable("Capture stream interrupted."))
                }
                connection.invalidationHandler = {
                    onFinish(nil)
                }
                connection.resume()
                proxy.openCaptureStream(payload, subscriber: receiver) { data, errorMessage in
                    let result: Result<MacFSWCaptureStartResponse, Error> = self.decodeResult(
                        data: data,
                        errorMessage: errorMessage,
                        as: MacFSWCaptureStartResponse.self
                    )
                    switch result {
                    case .success:
                        state.finish(.success(MacFSWCaptureHandle {
                            connectionBox.invalidate()
                        }))
                    case .failure(let error):
                        state.finish(.failure(error))
                    }
                }
            } catch {
                state.finish(.failure(error))
            }
        }
    }

    private func decodeResult<T: Decodable>(data: Data?, errorMessage: String?, as type: T.Type) -> Result<T, Error> {
        if let errorMessage {
            return .failure(MacFSWClientError.backend(errorMessage))
        }
        guard let data else {
            return .failure(MacFSWClientError.invalidResponse)
        }
        do {
            return .success(try decoder.decode(T.self, from: data))
        } catch {
            return .failure(error)
        }
    }
}

public enum MacFSWClientError: Error, LocalizedError, Sendable {
    case xpcUnavailable(String)
    case invalidResponse
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case .xpcUnavailable(let message):
            "XPC unavailable: \(message)"
        case .invalidResponse:
            "The capture service returned an invalid response."
        case .backend(let message):
            message
        }
    }
}

private final class XPCConnectionBox: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }

    func invalidate() {
        connection.invalidate()
    }
}

private final class XPCEventReceiver: NSObject, MacFSWCaptureEventSubscriber, @unchecked Sendable {
    private let decoder = JSONDecoder.macfsw
    private let onBatch: @Sendable (MacFSWEventBatch) -> Void
    private let onFinish: @Sendable (Error?) -> Void

    init(
        onBatch: @escaping @Sendable (MacFSWEventBatch) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) {
        self.onBatch = onBatch
        self.onFinish = onFinish
    }

    func eventBatch(_ payload: Data) {
        do {
            onBatch(try decoder.decode(MacFSWEventBatch.self, from: payload))
        } catch {
            onFinish(error)
        }
    }

    func captureFinished(_ errorMessage: String?) {
        onFinish(errorMessage.map { MacFSWClientError.backend($0) })
    }
}

private final class XPCRequestState<T: Sendable>: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let continuation: CheckedContinuation<T, Error>
    private let lock = NSLock()
    private var didFinish = false

    init(connection: NSXPCConnection, continuation: CheckedContinuation<T, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            connection.invalidate()
            continuation.resume(throwing: error)
        }
    }
}
