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
