import Foundation
import GRDB

extension MacFSWSQLiteEventStore {
    public func count(matching query: MacFSWEventQuery) async throws -> Int {
        let total = try await totalCount(matching: query)
        return query.visibleCount(totalCount: total)
    }

    public func totalCount(matching query: MacFSWEventQuery) async throws -> Int {
        let compiled = MacFSWSQLQueryCompiler.compile(query)
        let sql = "SELECT COUNT(*) FROM events WHERE \(compiled.whereSQL)"
        let arguments = MacFSWSQLQueryCompiler.arguments(compiled.arguments)
        return try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: sql,
                arguments: arguments
            ) ?? 0
        }
    }

    public func createResultSnapshot(
        matching query: MacFSWEventQuery,
        sortOrder: MacFSWEventSortOrder = .oldestFirst
    ) async throws -> MacFSWEventResultSnapshot {
        let snapshotID = UUID().uuidString
        let total = try await totalCount(matching: query)
        let visibleCount = query.visibleCount(totalCount: total)
        resultSnapshots[snapshotID] = StoredResultSnapshot(
            query: query,
            sortOrder: sortOrder,
            totalCount: total,
            visibleCount: visibleCount
        )
        return MacFSWEventResultSnapshot(id: snapshotID, totalCount: total, visibleCount: visibleCount)
    }

    public func deleteResultSnapshots(_ snapshotIDs: [String]) {
        for snapshotID in snapshotIDs {
            resultSnapshots[snapshotID] = nil
        }
    }

    public func rowSummaries(
        in snapshot: MacFSWEventResultSnapshot,
        visibleRange: Range<Int>
    ) async throws -> [MacFSWEventRowSummary] {
        guard let stored = resultSnapshots[snapshot.id] else {
            return []
        }
        return try await rowSummaries(
            matching: stored.query,
            visibleRange: visibleRange,
            totalCount: stored.totalCount,
            sortOrder: stored.sortOrder
        )
    }

    public func event(
        in snapshot: MacFSWEventResultSnapshot,
        visibleRow: Int
    ) async throws -> MacFSWFileEvent? {
        guard let stored = resultSnapshots[snapshot.id],
              visibleRow >= 0,
              visibleRow < stored.visibleCount else {
            return nil
        }
        return try await event(
            matching: stored.query,
            visibleRow: visibleRow,
            totalCount: stored.totalCount,
            sortOrder: stored.sortOrder
        )
    }

    public func visibleRowIndex(
        of id: UUID,
        in snapshot: MacFSWEventResultSnapshot
    ) async throws -> Int? {
        guard let stored = resultSnapshots[snapshot.id] else {
            return nil
        }
        return try await visibleRowIndex(
            of: id,
            matching: stored.query,
            totalCount: stored.totalCount,
            sortOrder: stored.sortOrder
        )
    }

    public func appendRowsToResultSnapshot(
        _ snapshot: MacFSWEventResultSnapshot,
        rows: [MacFSWEventRowSummary],
        limit: Int
    ) -> MacFSWEventResultSnapshot {
        let hasVisibleLimit = limit > 0
        let visibleLimit = hasVisibleLimit ? limit : Int.max
        let currentTotal = resultSnapshots[snapshot.id]?.totalCount ?? snapshot.totalCount
        let currentVisible = resultSnapshots[snapshot.id]?.visibleCount ?? snapshot.visibleCount
        let nextTotal = currentTotal + rows.count
        let nextVisible = hasVisibleLimit ? min(visibleLimit, currentVisible + rows.count) : currentVisible + rows.count
        if var stored = resultSnapshots[snapshot.id] {
            stored.totalCount = nextTotal
            stored.visibleCount = nextVisible
            resultSnapshots[snapshot.id] = stored
        }
        return MacFSWEventResultSnapshot(id: snapshot.id, totalCount: nextTotal, visibleCount: nextVisible)
    }

    public func rowSummaries(
        matching query: MacFSWEventQuery,
        visibleRange: Range<Int>,
        sortOrder: MacFSWEventSortOrder = .oldestFirst
    ) async throws -> [MacFSWEventRowSummary] {
        let total = try await totalCount(matching: query)
        return try await rowSummaries(
            matching: query,
            visibleRange: visibleRange,
            totalCount: total,
            sortOrder: sortOrder
        )
    }

    private func rowSummaries(
        matching query: MacFSWEventQuery,
        visibleRange: Range<Int>,
        totalCount: Int,
        sortOrder: MacFSWEventSortOrder = .oldestFirst
    ) async throws -> [MacFSWEventRowSummary] {
        let window = MacFSWSQLQueryCompiler.visibleWindow(
            totalCount: totalCount,
            limit: query.limit,
            requestedRange: visibleRange
        )
        guard window.limit > 0 else {
            return []
        }

        let compiled = MacFSWSQLQueryCompiler.compile(query)
        var arguments = compiled.arguments
        arguments.append(MacFSWSQLValue(window.limit))
        arguments.append(MacFSWSQLValue(window.offset))
        let sql = """
        SELECT id, sequence, timestampNS, eventType, operationClass,
               processName, pid, targetPath, sourcePath, detailSummary, signingID, teamID
        FROM events
        WHERE \(compiled.whereSQL)
        ORDER BY \(MacFSWSQLQueryCompiler.orderClause(sortOrder))
        LIMIT ? OFFSET ?
        """
        let statementArguments = MacFSWSQLQueryCompiler.arguments(arguments)

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: statementArguments
            )
            return try rows.map(rowSummary(from:))
        }
    }

    public func event(id: UUID) async throws -> MacFSWFileEvent? {
        let idText = id.uuidString
        return try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM events WHERE id = ?",
                arguments: [idText]
            ) else {
                return nil
            }
            return try eventRecord(from: row)
        }
    }

    /// Full events matching `query` in `sortOrder`. A `limit` of 0 returns
    /// every match; `offset` skips that many matches first.
    public func events(
        matching query: MacFSWEventQuery,
        sortOrder: MacFSWEventSortOrder = .oldestFirst,
        limit: Int = 0,
        offset: Int = 0
    ) async throws -> [MacFSWFileEvent] {
        let compiled = MacFSWSQLQueryCompiler.compile(query)
        var arguments = compiled.arguments
        arguments.append(MacFSWSQLValue(limit > 0 ? limit : -1))
        arguments.append(MacFSWSQLValue(offset))
        let sql = """
        SELECT *
        FROM events
        WHERE \(compiled.whereSQL)
        ORDER BY \(MacFSWSQLQueryCompiler.orderClause(sortOrder))
        LIMIT ? OFFSET ?
        """
        let statementArguments = MacFSWSQLQueryCompiler.arguments(arguments)

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: statementArguments)
            return try rows.map(eventRecord(from:))
        }
    }

    public func event(
        matching query: MacFSWEventQuery,
        visibleRow: Int,
        sortOrder: MacFSWEventSortOrder = .oldestFirst
    ) async throws -> MacFSWFileEvent? {
        let total = try await totalCount(matching: query)
        return try await event(
            matching: query,
            visibleRow: visibleRow,
            totalCount: total,
            sortOrder: sortOrder
        )
    }

    private func event(
        matching query: MacFSWEventQuery,
        visibleRow: Int,
        totalCount: Int,
        sortOrder: MacFSWEventSortOrder = .oldestFirst
    ) async throws -> MacFSWFileEvent? {
        guard visibleRow >= 0 else {
            return nil
        }

        let window = MacFSWSQLQueryCompiler.visibleWindow(
            totalCount: totalCount,
            limit: query.limit,
            requestedRange: visibleRow..<(visibleRow + 1)
        )
        guard window.limit == 1 else {
            return nil
        }

        let compiled = MacFSWSQLQueryCompiler.compile(query)
        var arguments = compiled.arguments
        arguments.append(MacFSWSQLValue(window.offset))
        let sql = """
        SELECT *
        FROM events
        WHERE \(compiled.whereSQL)
        ORDER BY \(MacFSWSQLQueryCompiler.orderClause(sortOrder))
        LIMIT 1 OFFSET ?
        """
        let statementArguments = MacFSWSQLQueryCompiler.arguments(arguments)

        return try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: sql,
                arguments: statementArguments
            ) else {
                return nil
            }
            return try eventRecord(from: row)
        }
    }

    /// One row per process with events matching `query`, most recently
    /// active first.
    public func processSummaries(matching query: MacFSWEventQuery = MacFSWEventQuery()) async throws -> [MacFSWProcessEventSummary] {
        let compiled = MacFSWSQLQueryCompiler.compile(query)
        let arguments = MacFSWSQLQueryCompiler.arguments(compiled.arguments)
        let sql = """
        SELECT
            'pid:' || CAST(pid AS TEXT) AS id,
            MAX(processName) AS processName,
            pid,
            MAX(auditToken) AS auditToken,
            MAX(executablePath) AS executablePath,
            MAX(signingID) AS signingID,
            MAX(teamID) AS teamID,
            MAX(uid) AS uid,
            MAX(gid) AS gid,
            COUNT(*) AS eventCount,
            MAX(timestampNS) AS lastEventNS,
            MAX(isPlatformBinary) AS isPlatformBinary,
            COUNT(DISTINCT auditToken || '|' || executablePath) AS identityCount
        FROM events
        WHERE \(compiled.whereSQL)
        GROUP BY pid
        ORDER BY lastEventNS DESC
        """

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map(processEventSummary(from:))
        }
    }

    public func operationSummaries(matching query: MacFSWEventQuery) async throws -> [MacFSWOperationEventSummary] {
        let compiled = MacFSWSQLQueryCompiler.compile(query)
        let arguments = MacFSWSQLQueryCompiler.arguments(compiled.arguments)
        let sql = """
        SELECT eventType, operationClass, COUNT(*) AS eventCount
        FROM events
        WHERE \(compiled.whereSQL)
        GROUP BY eventType, operationClass
        ORDER BY eventCount DESC, eventType ASC
        """

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return try rows.map(operationEventSummary(from:))
        }
    }

    public func distinctValues(
        for field: MacFSWQueryField,
        matching query: MacFSWEventQuery,
        limit: Int
    ) async throws -> [MacFSWFacetValue] {
        guard let column = MacFSWSQLQueryCompiler.facetColumn(for: field), limit > 0 else {
            return []
        }
        let compiled = MacFSWSQLQueryCompiler.compile(query)
        let arguments = MacFSWSQLQueryCompiler.arguments(compiled.arguments)
        let sql = """
        SELECT \(column) AS facetValue, COUNT(*) AS eventCount
        FROM events
        WHERE (\(compiled.whereSQL)) AND \(column) <> ''
        GROUP BY facetValue
        ORDER BY eventCount DESC, facetValue ASC
        LIMIT \(limit)
        """

        return try await dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                MacFSWFacetValue(value: row["facetValue"], count: row["eventCount"])
            }
        }
    }

    public func visibleRowIndex(
        of id: UUID,
        matching query: MacFSWEventQuery,
        sortOrder: MacFSWEventSortOrder = .oldestFirst
    ) async throws -> Int? {
        let total = try await totalCount(matching: query)
        return try await visibleRowIndex(
            of: id,
            matching: query,
            totalCount: total,
            sortOrder: sortOrder
        )
    }

    private func visibleRowIndex(
        of id: UUID,
        matching query: MacFSWEventQuery,
        totalCount: Int,
        sortOrder: MacFSWEventSortOrder = .oldestFirst
    ) async throws -> Int? {
        guard let event = try await event(id: id), query.matches(event) else {
            return nil
        }

        let visibleCount = query.visibleCount(totalCount: totalCount)
        let visibleStart = max(0, totalCount - visibleCount)
        let compiled = MacFSWSQLQueryCompiler.compile(query)
        let bound = MacFSWSQLQueryCompiler.orderBoundClause(for: event, sortOrder: sortOrder)
        let combined = MacFSWCompiledSQL(
            whereSQL: "(\(compiled.whereSQL)) AND (\(bound.whereSQL))",
            arguments: compiled.arguments + bound.arguments
        )
        let sql = "SELECT COUNT(*) FROM events WHERE \(combined.whereSQL)"
        let arguments = MacFSWSQLQueryCompiler.arguments(combined.arguments)
        let beforeOrEqual = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: sql,
                arguments: arguments
            ) ?? 0
        }
        let allRowsIndex = beforeOrEqual - 1
        guard allRowsIndex >= visibleStart else {
            return nil
        }
        return allRowsIndex - visibleStart
    }
}

struct StoredResultSnapshot: Sendable {
    var query: MacFSWEventQuery
    var sortOrder: MacFSWEventSortOrder
    var totalCount: Int
    var visibleCount: Int
}

private func rowSummary(from row: Row) throws -> MacFSWEventRowSummary {
    let sequence: Int64 = row["sequence"]
    let timestampNS: Int64 = row["timestampNS"]
    let signingID: String? = row["signingID"]
    let teamID: String? = row["teamID"]
    return MacFSWEventRowSummary(
        id: try row.uuid("id"),
        sequence: UInt64(sequence),
        timestampNS: UInt64(timestampNS),
        eventType: try row.value("eventType"),
        operationClass: try row.value("operationClass"),
        processName: row["processName"],
        pid: Int32(row["pid"] as Int),
        targetPath: row["targetPath"],
        sourcePath: row["sourcePath"],
        detailSummary: row["detailSummary"],
        signingSummary: signingID ?? teamID ?? ""
    )
}

private func processEventSummary(from row: Row) -> MacFSWProcessEventSummary {
    let pid: Int = row["pid"]
    let uid: Int = row["uid"]
    let gid: Int = row["gid"]
    let lastEventNS: Int64 = row["lastEventNS"]
    let signingID: String? = row["signingID"]
    let teamID: String? = row["teamID"]
    let isPlatformBinary: Int = row["isPlatformBinary"]
    return MacFSWProcessEventSummary(
        id: row["id"],
        processName: row["processName"],
        pid: Int32(pid),
        auditToken: row["auditToken"],
        executablePath: row["executablePath"],
        signingSummary: signingID ?? teamID ?? "",
        uid: UInt32(uid),
        gid: UInt32(gid),
        eventCount: row["eventCount"],
        lastEventNS: UInt64(lastEventNS),
        isPlatformBinary: isPlatformBinary != 0,
        identityCount: row["identityCount"]
    )
}

private func operationEventSummary(from row: Row) throws -> MacFSWOperationEventSummary {
    MacFSWOperationEventSummary(
        eventType: try row.value("eventType"),
        operationClass: try row.value("operationClass"),
        eventCount: row["eventCount"]
    )
}
