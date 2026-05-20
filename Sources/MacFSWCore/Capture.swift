import Foundation

public enum MacFSWCaptureState: String, Codable, Equatable, Sendable {
    case idle
    case connecting
    case recording
    case stopping
    case stopped
    case degraded
    case failed
}

public enum MacFSWCaptureProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case focusedMutations
    case verboseReads
    case fullSystemBurst

    public var id: String { rawValue }
}

public struct MacFSWCaptureConfig: Codable, Equatable, Sendable {
    public var profile: MacFSWCaptureProfile
    public var eventTypes: [MacFSWEventType]
    public var targetPIDs: [Int32]
    public var targetProcessNames: [String]
    public var targetExecutablePaths: [String]
    public var includePaths: [String]
    public var excludePaths: [String]
    public var excludedProcessNames: [String]
    public var muteSelf: Bool
    public var batchSize: Int
    public var batchIntervalMS: Int
    public var maxEventsPerSecond: Int?
    public var maxCaptureDurationSeconds: Int

    public init(
        profile: MacFSWCaptureProfile = .focusedMutations,
        eventTypes: [MacFSWEventType]? = nil,
        targetPIDs: [Int32] = [],
        targetProcessNames: [String] = [],
        targetExecutablePaths: [String] = [],
        includePaths: [String] = [],
        excludePaths: [String] = [],
        excludedProcessNames: [String] = ["MacFSW", "MacFSWApp", "MacFSWSystemExtension"],
        muteSelf: Bool = true,
        batchSize: Int = 256,
        batchIntervalMS: Int = 100,
        maxEventsPerSecond: Int? = nil,
        maxCaptureDurationSeconds: Int = 600
    ) {
        self.profile = profile
        self.eventTypes = eventTypes ?? Self.defaultEventTypes(for: profile)
        self.targetPIDs = targetPIDs
        self.targetProcessNames = targetProcessNames
        self.targetExecutablePaths = targetExecutablePaths
        self.includePaths = includePaths
        self.excludePaths = excludePaths
        self.excludedProcessNames = excludedProcessNames
        self.muteSelf = muteSelf
        self.batchSize = max(1, batchSize)
        self.batchIntervalMS = max(10, batchIntervalMS)
        self.maxEventsPerSecond = maxEventsPerSecond
        self.maxCaptureDurationSeconds = max(5, maxCaptureDurationSeconds)
    }

    public static func defaultEventTypes(for profile: MacFSWCaptureProfile) -> [MacFSWEventType] {
        switch profile {
        case .focusedMutations:
            MacFSWEventType.defaultCaptureTypes
        case .verboseReads, .fullSystemBurst:
            MacFSWEventType.verboseCaptureTypes
        }
    }

    public var transportSafe: MacFSWCaptureConfig {
        var copy = self
        let safeEventTypes = eventTypes.filter(\.isTransportSafeCaptureType)
        copy.eventTypes = safeEventTypes.isEmpty
            ? Self.defaultEventTypes(for: profile)
            : safeEventTypes
        return copy
    }
}

public struct MacFSWCaptureStats: Codable, Equatable, Sendable {
    public var receivedEvents: UInt64
    public var deliveredEvents: UInt64
    public var droppedEvents: UInt64
    public var queuedEvents: Int
    public var activeSubscriptions: [MacFSWEventType]
    public var startedAt: Date?
    public var lastEventAt: Date?

    public init(
        receivedEvents: UInt64 = 0,
        deliveredEvents: UInt64 = 0,
        droppedEvents: UInt64 = 0,
        queuedEvents: Int = 0,
        activeSubscriptions: [MacFSWEventType] = [],
        startedAt: Date? = nil,
        lastEventAt: Date? = nil
    ) {
        self.receivedEvents = receivedEvents
        self.deliveredEvents = deliveredEvents
        self.droppedEvents = droppedEvents
        self.queuedEvents = queuedEvents
        self.activeSubscriptions = activeSubscriptions
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
    }
}

public struct MacFSWCaptureHealth: Codable, Equatable, Sendable {
    public var state: MacFSWCaptureState
    public var endpointSecurityAvailable: Bool
    public var endpointSecurityAuthorized: Bool
    public var fullDiskAccessHint: Bool
    public var stats: MacFSWCaptureStats
    public var message: String

    public init(
        state: MacFSWCaptureState = .idle,
        endpointSecurityAvailable: Bool = true,
        endpointSecurityAuthorized: Bool = false,
        fullDiskAccessHint: Bool = false,
        stats: MacFSWCaptureStats = MacFSWCaptureStats(),
        message: String = "Capture is idle."
    ) {
        self.state = state
        self.endpointSecurityAvailable = endpointSecurityAvailable
        self.endpointSecurityAuthorized = endpointSecurityAuthorized
        self.fullDiskAccessHint = fullDiskAccessHint
        self.stats = stats
        self.message = message
    }
}

public struct MacFSWCaptureStreamRequest: Codable, Equatable, Sendable {
    public var config: MacFSWCaptureConfig

    public init(config: MacFSWCaptureConfig) {
        self.config = config
    }
}

public struct MacFSWCaptureStartResponse: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var health: MacFSWCaptureHealth

    public init(accepted: Bool, health: MacFSWCaptureHealth) {
        self.accepted = accepted
        self.health = health
    }
}

public struct MacFSWEventBatch: Codable, Equatable, Sendable {
    public var events: [MacFSWFileEvent]
    public var stats: MacFSWCaptureStats

    public init(events: [MacFSWFileEvent], stats: MacFSWCaptureStats) {
        self.events = events
        self.stats = stats
    }
}

public protocol MacFSWCaptureClient: Sendable {
    func health() async throws -> MacFSWCaptureHealth
    func openCaptureStream(
        config: MacFSWCaptureConfig,
        onBatch: @escaping @Sendable (MacFSWEventBatch) -> Void,
        onFinish: @escaping @Sendable (Error?) -> Void
    ) async throws -> MacFSWCaptureHandle
}

public final class MacFSWCaptureHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let stopHandler: @Sendable () -> Void

    public init(stopHandler: @escaping @Sendable () -> Void) {
        self.stopHandler = stopHandler
    }

    public func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        stopHandler()
    }
}

@objc public protocol MacFSWCaptureXPCProtocol {
    func openCaptureStream(
        _ payload: Data,
        subscriber: MacFSWCaptureEventSubscriber,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    )

    func health(withReply reply: @escaping @Sendable (Data?, String?) -> Void)
}

@objc public protocol MacFSWCaptureEventSubscriber {
    func eventBatch(_ payload: Data)
    func captureFinished(_ errorMessage: String?)
}

public enum MacFSWXPCInterfaces {
    public static func captureServiceInterface() -> NSXPCInterface {
        let serviceInterface = NSXPCInterface(with: MacFSWCaptureXPCProtocol.self)
        serviceInterface.setInterface(
            captureEventSubscriberInterface(),
            for: #selector(MacFSWCaptureXPCProtocol.openCaptureStream(_:subscriber:withReply:)),
            argumentIndex: 1,
            ofReply: false
        )
        return serviceInterface
    }

    public static func captureEventSubscriberInterface() -> NSXPCInterface {
        NSXPCInterface(with: MacFSWCaptureEventSubscriber.self)
    }
}
