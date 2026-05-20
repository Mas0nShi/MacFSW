import Foundation

public struct MacFSWEventRowSummary: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var sequence: UInt64
    public var timestampNS: UInt64
    public var eventType: MacFSWEventType
    public var operationClass: MacFSWOperationClass
    public var risk: MacFSWRiskLevel
    public var processName: String
    public var pid: Int32
    public var targetPath: String
    public var sourcePath: String?
    public var detailSummary: String
    public var signingSummary: String

    public init(
        id: UUID,
        sequence: UInt64,
        timestampNS: UInt64,
        eventType: MacFSWEventType,
        operationClass: MacFSWOperationClass,
        risk: MacFSWRiskLevel,
        processName: String,
        pid: Int32,
        targetPath: String,
        sourcePath: String?,
        detailSummary: String,
        signingSummary: String
    ) {
        self.id = id
        self.sequence = sequence
        self.timestampNS = timestampNS
        self.eventType = eventType
        self.operationClass = operationClass
        self.risk = risk
        self.processName = processName
        self.pid = pid
        self.targetPath = targetPath
        self.sourcePath = sourcePath
        self.detailSummary = detailSummary
        self.signingSummary = signingSummary
    }

    public init(event: MacFSWFileEvent) {
        self.init(
            id: event.id,
            sequence: event.sequence,
            timestampNS: event.timestampNS,
            eventType: event.eventType,
            operationClass: event.operationClass,
            risk: event.risk,
            processName: event.process.processName,
            pid: event.process.pid,
            targetPath: event.targetPath,
            sourcePath: event.sourcePath,
            detailSummary: event.operationDetailSummary,
            signingSummary: event.process.signingID ?? event.process.teamID ?? ""
        )
    }
}

public struct MacFSWProcessEventSummary: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var processName: String
    public var pid: Int32
    public var auditToken: String
    public var executablePath: String
    public var signingSummary: String
    public var uid: UInt32
    public var gid: UInt32
    public var eventCount: Int
    public var lastEventNS: UInt64
    public var isPlatformBinary: Bool
    public var identityCount: Int

    public init(
        id: String,
        processName: String,
        pid: Int32,
        auditToken: String,
        executablePath: String,
        signingSummary: String,
        uid: UInt32,
        gid: UInt32,
        eventCount: Int,
        lastEventNS: UInt64,
        isPlatformBinary: Bool,
        identityCount: Int = 1
    ) {
        self.id = id
        self.processName = processName
        self.pid = pid
        self.auditToken = auditToken
        self.executablePath = executablePath
        self.signingSummary = signingSummary
        self.uid = uid
        self.gid = gid
        self.eventCount = eventCount
        self.lastEventNS = lastEventNS
        self.isPlatformBinary = isPlatformBinary
        self.identityCount = identityCount
    }
}

public struct MacFSWEventResultSnapshot: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var totalCount: Int
    public var visibleCount: Int

    public init(id: String, totalCount: Int, visibleCount: Int) {
        self.id = id
        self.totalCount = totalCount
        self.visibleCount = visibleCount
    }
}

public struct MacFSWOperationEventSummary: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var eventType: MacFSWEventType
    public var operationClass: MacFSWOperationClass
    public var eventCount: Int

    public var id: String {
        eventType.rawValue
    }

    public init(
        eventType: MacFSWEventType,
        operationClass: MacFSWOperationClass,
        eventCount: Int
    ) {
        self.eventType = eventType
        self.operationClass = operationClass
        self.eventCount = eventCount
    }
}

public protocol MacFSWEventStore: Sendable {
    func appendReturningEvents(_ incoming: [MacFSWFileEvent]) async throws -> MacFSWEventAppendResult
    func clear() async throws
    func count(matching query: MacFSWEventQuery) async throws -> Int
    func rowSummaries(
        matching query: MacFSWEventQuery,
        visibleRange: Range<Int>,
        sortOrder: MacFSWEventSortOrder
    ) async throws -> [MacFSWEventRowSummary]
    func event(id: UUID) async throws -> MacFSWFileEvent?
    func event(
        matching query: MacFSWEventQuery,
        visibleRow: Int,
        sortOrder: MacFSWEventSortOrder
    ) async throws -> MacFSWFileEvent?
    func visibleRowIndex(
        of id: UUID,
        matching query: MacFSWEventQuery,
        sortOrder: MacFSWEventSortOrder
    ) async throws -> Int?
    func snapshot() async throws -> [MacFSWFileEvent]
}
