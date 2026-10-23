import Foundation
import MacFSWCore

// Results shared by the `macfsw` subcommands and MCP tools. They are kept
// compact and flat on purpose: an agent pays for every token it reads.

public struct ProcessRow: Codable, Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var executable: String
    /// Signing identifier, falling back to Team ID; empty when unsigned.
    public var signing: String
    public var platformBinary: Bool
    public var events: Int
    public var lastEvent: Date

    init(_ summary: MacFSWProcessEventSummary) {
        pid = summary.pid
        name = summary.processName
        executable = summary.executablePath
        signing = summary.signingSummary
        platformBinary = summary.isPlatformBinary
        events = summary.eventCount
        lastEvent = Date(nanosecondsSince1970: summary.lastEventNS)
    }
}

public struct ProcessList: Codable, Equatable, Sendable {
    public var query: String
    public var diagnostics: [String]
    /// Processes with matching events before `limit` was applied.
    public var total: Int
    public var processes: [ProcessRow]
}

public struct EventRow: Codable, Equatable, Sendable {
    public var id: UUID
    public var sequence: UInt64
    public var time: Date
    public var operation: String
    public var process: String
    public var pid: Int32
    public var path: String
    public var sourcePath: String?
    public var detail: String

    init(_ event: MacFSWFileEvent) {
        id = event.id
        sequence = event.sequence
        time = Date(nanosecondsSince1970: event.timestampNS)
        operation = event.eventType.rawValue
        process = event.process.processName
        pid = event.process.pid
        path = event.targetPath
        sourcePath = event.sourcePath
        detail = event.operationDetailSummary
    }
}

public struct EventPage: Codable, Equatable, Sendable {
    /// The query as the parser understood it, in canonical form.
    public var query: String
    /// Places where the parser had to guess; empty when the query was clean.
    public var diagnostics: [String]
    public var total: Int
    public var offset: Int
    public var events: [EventRow]
}

public struct CountedValue: Codable, Equatable, Sendable {
    public var value: String
    public var count: Int
}

public struct EventSummary: Codable, Equatable, Sendable {
    public var query: String
    public var diagnostics: [String]
    public var total: Int
    public var operations: [CountedValue]
    public var topProcesses: [CountedValue]
    public var topExecutables: [CountedValue]
    public var topSigningIDs: [CountedValue]
}

public struct SessionInfo: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Recorded by this process into a temporary store.
        case capture
        /// Opened from a `.macfsw-session` file.
        case file
    }

    public var name: String
    public var source: Source
    public var path: String?
    public var events: Int
    public var captureState: MacFSWCaptureState
    public var deliveredEvents: UInt64
    public var droppedEvents: UInt64
}

public struct Status: Codable, Equatable, Sendable {
    public var `extension`: ExtensionStatus
    public var session: SessionInfo?
}

extension Date {
    init(nanosecondsSince1970 nanoseconds: UInt64) {
        self.init(timeIntervalSince1970: TimeInterval(nanoseconds) / 1_000_000_000)
    }
}
