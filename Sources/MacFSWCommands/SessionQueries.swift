import Foundation
import MacFSWCore

public enum EventOrder: String, Codable, CaseIterable, Sendable {
    case oldest
    case newest

    var sortOrder: MacFSWEventSortOrder {
        self == .oldest ? .oldestFirst : .newestFirst
    }
}

/// Read-only operations over one session's events, all driven by the
/// MacFSW query language so the CLI, the MCP tools, and the app's command
/// bar agree on what a query means.
public struct SessionQueries: Sendable {
    public static let maxLimit = 1_000

    let store: MacFSWSQLiteEventStore

    public init(store: MacFSWSQLiteEventStore) {
        self.store = store
    }

    public func processes(matching queryText: String = "", limit: Int = 100) async throws -> ProcessList {
        let parsed = Parsed(queryText)
        let summaries = try await store.processSummaries(matching: parsed.query)
        return ProcessList(
            query: parsed.canonicalText,
            diagnostics: parsed.diagnostics,
            total: summaries.count,
            processes: summaries.prefix(Self.clamp(limit)).map(ProcessRow.init)
        )
    }

    public func events(
        matching queryText: String = "",
        limit: Int = 100,
        offset: Int = 0,
        order: EventOrder = .oldest
    ) async throws -> EventPage {
        let parsed = Parsed(queryText)
        async let total = store.count(matching: parsed.query)
        async let events = store.events(
            matching: parsed.query,
            sortOrder: order.sortOrder,
            limit: Self.clamp(limit),
            offset: offset
        )
        return try await EventPage(
            query: parsed.canonicalText,
            diagnostics: parsed.diagnostics,
            total: total,
            offset: max(0, offset),
            events: events.map(EventRow.init)
        )
    }

    public func event(id: UUID) async throws -> MacFSWFileEvent {
        guard let event = try await store.event(id: id) else {
            throw CommandError.eventNotFound(id)
        }
        return event
    }

    public func summary(matching queryText: String = "", top: Int = 10) async throws -> EventSummary {
        let parsed = Parsed(queryText)
        async let total = store.count(matching: parsed.query)
        async let operations = store.operationSummaries(matching: parsed.query)
        async let processes = store.distinctValues(for: .processName, matching: parsed.query, limit: top)
        async let executables = store.distinctValues(for: .executable, matching: parsed.query, limit: top)
        async let signingIDs = store.distinctValues(for: .signingID, matching: parsed.query, limit: top)
        let counted = { (values: [MacFSWFacetValue]) in values.map { CountedValue(value: $0.value, count: $0.count) } }
        return try await EventSummary(
            query: parsed.canonicalText,
            diagnostics: parsed.diagnostics,
            total: total,
            operations: operations.map { CountedValue(value: $0.eventType.rawValue, count: $0.eventCount) },
            topProcesses: counted(processes),
            topExecutables: counted(executables),
            topSigningIDs: counted(signingIDs)
        )
    }

    private static func clamp(_ limit: Int) -> Int {
        min(max(1, limit), maxLimit)
    }
}

private struct Parsed {
    let query: MacFSWEventQuery
    let canonicalText: String
    let diagnostics: [String]

    init(_ text: String) {
        let result = MacFSWQueryParser.parseDetailed(text)
        query = result.query
        canonicalText = result.query.expression.map(MacFSWQueryPrinter.canonicalText(for:)) ?? ""
        diagnostics = result.diagnostics.map(\.message)
    }
}
