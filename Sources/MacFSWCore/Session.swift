import Foundation

public enum MacFSWSessionSource: String, Codable, Sendable {
    case live
    case openedSession
}

public struct MacFSWSessionMetadata: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var appVersion: String
    public var createdAt: Date
    public var updatedAt: Date
    public var source: MacFSWSessionSource

    public init(
        schemaVersion: Int = 1,
        appVersion: String = "unknown",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        source: MacFSWSessionSource = .live
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
    }
}

public struct MacFSWResearchSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var targetDescription: String
    public var captureConfig: MacFSWCaptureConfig
    public var metadata: MacFSWSessionMetadata
    public var annotations: [MacFSWAnnotation]
    public var savedQueries: [MacFSWSavedQuery]

    public init(
        id: UUID = UUID(),
        name: String = "Untitled Session",
        targetDescription: String = "",
        captureConfig: MacFSWCaptureConfig = MacFSWCaptureConfig(),
        metadata: MacFSWSessionMetadata = MacFSWSessionMetadata(),
        annotations: [MacFSWAnnotation] = [],
        savedQueries: [MacFSWSavedQuery] = MacFSWSavedQuery.defaults
    ) {
        self.id = id
        self.name = name
        self.targetDescription = targetDescription
        self.captureConfig = captureConfig
        self.metadata = metadata
        self.annotations = annotations
        self.savedQueries = savedQueries
    }
}

public struct MacFSWSavedQuery: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var query: MacFSWEventQuery

    public init(id: UUID = UUID(), name: String, query: MacFSWEventQuery) {
        self.id = id
        self.name = name
        self.query = query
    }

    public static var defaults: [MacFSWSavedQuery] {
        [
            MacFSWSavedQuery(name: "All Events", query: MacFSWEventQuery()),
            MacFSWSavedQuery(name: "Mutations", query: MacFSWQueryParser.parse("mutation:true")),
            MacFSWSavedQuery(name: "Deletes", query: MacFSWQueryParser.parse("op:unlink")),
            MacFSWSavedQuery(name: "Metadata", query: MacFSWQueryParser.parse("class:metadata")),
        ]
    }
}

public struct MacFSWEventAppendResult: Sendable {
    public var events: [MacFSWFileEvent]
    public var stats: MacFSWCaptureStats

    public init(events: [MacFSWFileEvent], stats: MacFSWCaptureStats) {
        self.events = events
        self.stats = stats
    }
}

public actor MacFSWInMemoryEventStore {
    private var events: [MacFSWFileEvent] = []
    private var nextSequence: UInt64 = 1
    private let maxEvents: Int
    private var droppedByMemoryLimit: UInt64 = 0

    public init(maxEvents: Int = 500_000) {
        self.maxEvents = max(1_000, maxEvents)
    }

    public func append(_ incoming: [MacFSWFileEvent]) -> MacFSWCaptureStats {
        appendReturningEvents(incoming).stats
    }

    public func appendReturningEvents(_ incoming: [MacFSWFileEvent]) -> MacFSWEventAppendResult {
        guard !incoming.isEmpty else {
            return MacFSWEventAppendResult(events: [], stats: stats())
        }

        var sequenced = incoming
        for index in sequenced.indices {
            sequenced[index].sequence = nextSequence
            nextSequence += 1
        }

        events.append(contentsOf: sequenced)
        if events.count > maxEvents {
            let overflow = events.count - maxEvents
            events.removeFirst(overflow)
            droppedByMemoryLimit += UInt64(overflow)
        }

        return MacFSWEventAppendResult(events: sequenced, stats: stats())
    }

    public func replace(with newEvents: [MacFSWFileEvent]) {
        events = newEvents
        nextSequence = (newEvents.map(\.sequence).max() ?? 0) + 1
        droppedByMemoryLimit = 0
    }

    public func clear() {
        events.removeAll(keepingCapacity: true)
        nextSequence = 1
        droppedByMemoryLimit = 0
    }

    public func query(_ query: MacFSWEventQuery, sortOrder: MacFSWEventSortOrder = .newestFirst) -> [MacFSWFileEvent] {
        let newestFirst = events
            .filter { query.matches($0) }
            .sorted { left, right in
                if left.timestampNS == right.timestampNS {
                    return left.sequence > right.sequence
                }
                return left.timestampNS > right.timestampNS
            }
        let visibleRows = query.hasVisibleLimit ? Array(newestFirst.prefix(query.limit)) : newestFirst
        switch sortOrder {
        case .newestFirst:
            return visibleRows
        case .oldestFirst:
            return visibleRows.reversed()
        }
    }

    public func snapshot() -> [MacFSWFileEvent] {
        events
    }

    public func distinctValues(
        for field: MacFSWQueryField,
        matching query: MacFSWEventQuery,
        limit: Int
    ) -> [MacFSWFacetValue] {
        guard limit > 0 else {
            return []
        }
        var counts: [String: Int] = [:]
        for event in events where query.matches(event) {
            let value: String
            switch field {
            case .processName:
                value = event.process.processName
            case .pid:
                value = String(event.process.pid)
            case .executable:
                value = event.process.executablePath
            case .signingID:
                value = event.process.signingID ?? ""
            case .teamID:
                value = event.process.teamID ?? ""
            default:
                return []
            }
            if !value.isEmpty {
                counts[value, default: 0] += 1
            }
        }
        var values = counts.map { (value: String, count: Int) in
            MacFSWFacetValue(value: value, count: count)
        }
        values.sort { left, right in
            left.count == right.count ? left.value < right.value : left.count > right.count
        }
        return Array(values.prefix(limit))
    }

    public func count() -> Int {
        events.count
    }

    public func memoryDroppedCount() -> UInt64 {
        droppedByMemoryLimit
    }

    private func stats() -> MacFSWCaptureStats {
        MacFSWCaptureStats(
            deliveredEvents: UInt64(events.count),
            droppedEvents: droppedByMemoryLimit,
            queuedEvents: 0,
            lastEventAt: events.last.map { Date(timeIntervalSince1970: TimeInterval($0.timestampNS) / 1_000_000_000) }
        )
    }
}
