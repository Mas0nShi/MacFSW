import Foundation
import GRDB

public enum MacFSWSQLiteStoreError: Error, LocalizedError, Sendable {
    case unsupportedFormat(URL)
    case missingSessionMetadata
    case invalidDatabasePath

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let url):
            "Unsupported MacFSW SQLite format: \(url.lastPathComponent)."
        case .missingSessionMetadata:
            "The MacFSW database is missing session metadata."
        case .invalidDatabasePath:
            "The MacFSW database path is invalid."
        }
    }
}

public actor MacFSWSQLiteEventStore: MacFSWEventStore {
    public nonisolated let url: URL
    private let dbQueue: DatabaseQueue
    private let ownedDirectoryURL: URL?
    private var nextSequence: UInt64
    private var didCleanupBackingStore = false
    private static let temporaryDirectoryPrefix = "macfsw-"
    private static let baseIndexSQL = [
        "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestampNS)",
        "CREATE INDEX IF NOT EXISTS idx_events_type ON events(eventType)",
        "CREATE INDEX IF NOT EXISTS idx_events_operation_class ON events(operationClass)",
        "CREATE INDEX IF NOT EXISTS idx_events_risk ON events(riskScore)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid ON events(pid)",
        "CREATE INDEX IF NOT EXISTS idx_events_process_name ON events(processName)",
        "CREATE INDEX IF NOT EXISTS idx_events_signing ON events(signingID)",
        "CREATE INDEX IF NOT EXISTS idx_events_team ON events(teamID)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid_audit_time ON events(pid, auditToken, timestampNS, sequence)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid_executable_time ON events(pid, executablePath, timestampNS, sequence)",
        "CREATE INDEX IF NOT EXISTS idx_result_rows_event ON result_rows(snapshotID, eventID)",
    ]
    private static let largeFilterIndexSQL = [
        "CREATE INDEX IF NOT EXISTS idx_events_pid_time ON events(pid, timestampNS, sequence)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid_operation_class_time ON events(pid, operationClass, timestampNS, sequence)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid_event_type_time ON events(pid, eventType, timestampNS, sequence)",
        "CREATE INDEX IF NOT EXISTS idx_events_operation_class_time ON events(operationClass, timestampNS, sequence)",
    ]

    public init(
        url: URL,
        createIfNeeded: Bool = true,
        defaultSession: MacFSWResearchSession? = nil,
        ownedDirectoryURL: URL? = nil
    ) throws {
        self.url = url
        self.ownedDirectoryURL = ownedDirectoryURL
        if !createIfNeeded {
            try Self.validateSQLiteHeader(at: url)
        }

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrate(dbQueue)
        if createIfNeeded {
            try Self.ensureSession(defaultSession ?? MacFSWResearchSession(), dbQueue: dbQueue)
        }
        self.nextSequence = try Self.readNextSequence(dbQueue)
    }

    public static func temporary(session: MacFSWResearchSession = MacFSWResearchSession()) throws -> MacFSWSQLiteEventStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.sqlite")
        return try MacFSWSQLiteEventStore(url: url, defaultSession: session, ownedDirectoryURL: directory)
    }

    public static func cleanupStaleTemporaryStores() throws {
        let fileManager = FileManager.default
        let directoryURLs = try fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directoryURL in directoryURLs where isManagedTemporaryDirectoryName(directoryURL.lastPathComponent) {
            let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }
            try fileManager.removeItem(at: directoryURL)
        }
    }

    private static func isManagedTemporaryDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryDirectoryPrefix) else {
            return false
        }
        let suffix = String(name.dropFirst(temporaryDirectoryPrefix.count))
        return UUID(uuidString: suffix) != nil
    }

    deinit {
        guard let ownedDirectoryURL, !didCleanupBackingStore else {
            return
        }
        try? FileManager.default.removeItem(at: ownedDirectoryURL)
    }

    public func cleanupBackingStore() async throws {
        guard let ownedDirectoryURL, !didCleanupBackingStore else {
            return
        }
        didCleanupBackingStore = true
        try dbQueue.close()
        if FileManager.default.fileExists(atPath: ownedDirectoryURL.path) {
            try FileManager.default.removeItem(at: ownedDirectoryURL)
        }
    }

    public func appendReturningEvents(_ incoming: [MacFSWFileEvent]) async throws -> MacFSWEventAppendResult {
        guard !incoming.isEmpty else {
            return MacFSWEventAppendResult(events: [], stats: try await stats())
        }

        var sequenced = incoming
        for index in sequenced.indices {
            sequenced[index].sequence = nextSequence
            nextSequence += 1
        }
        let eventsToInsert = sequenced

        try await dbQueue.write { db in
            for event in eventsToInsert {
                try Self.insert(event, db: db)
            }
        }

        return MacFSWEventAppendResult(events: sequenced, stats: try await stats())
    }

    public func clear() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM result_snapshots")
            try db.execute(sql: "DELETE FROM event_fts")
            try db.execute(sql: "DELETE FROM events")
        }
        nextSequence = 1
    }

    public func replace(with events: [MacFSWFileEvent]) async throws {
        try await clear()
        _ = try await appendReturningEvents(events)
    }

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
        let compiled = MacFSWSQLQueryCompiler.compile(query)
        let compiledArguments = MacFSWSQLQueryCompiler.arguments(compiled.arguments)
        return try await dbQueue.write { db in
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM events WHERE \(compiled.whereSQL)",
                arguments: compiledArguments
            ) ?? 0
            let visibleCount = query.visibleCount(totalCount: total)
            try db.execute(
                sql: """
                INSERT INTO result_snapshots (id, createdAt, totalCount, visibleCount)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [snapshotID, Date().timeIntervalSince1970, total, visibleCount]
            )
            guard visibleCount > 0 else {
                return MacFSWEventResultSnapshot(id: snapshotID, totalCount: total, visibleCount: 0)
            }

            let snapshotSQL: String
            var arguments = compiled.arguments
            arguments.insert(MacFSWSQLValue(snapshotID), at: 0)
            switch sortOrder {
            case .oldestFirst:
                if query.hasVisibleLimit {
                    snapshotSQL = """
                    INSERT INTO result_rows (snapshotID, rowIndex, eventID, sequence)
                    SELECT ?, ROW_NUMBER() OVER (ORDER BY timestampNS ASC, sequence ASC) - 1, id, sequence
                    FROM (
                        SELECT id, sequence, timestampNS
                        FROM events
                        WHERE \(compiled.whereSQL)
                        ORDER BY timestampNS DESC, sequence DESC
                        LIMIT ?
                    )
                    ORDER BY timestampNS ASC, sequence ASC
                    """
                    arguments.append(MacFSWSQLValue(visibleCount))
                } else {
                    snapshotSQL = """
                    INSERT INTO result_rows (snapshotID, rowIndex, eventID, sequence)
                    SELECT ?, ROW_NUMBER() OVER (ORDER BY timestampNS ASC, sequence ASC) - 1, id, sequence
                    FROM events
                    WHERE \(compiled.whereSQL)
                    ORDER BY timestampNS ASC, sequence ASC
                    """
                }
            case .newestFirst:
                if query.hasVisibleLimit {
                    snapshotSQL = """
                    INSERT INTO result_rows (snapshotID, rowIndex, eventID, sequence)
                    SELECT ?, ROW_NUMBER() OVER (ORDER BY timestampNS DESC, sequence DESC) - 1, id, sequence
                    FROM (
                        SELECT id, sequence, timestampNS
                        FROM events
                        WHERE \(compiled.whereSQL)
                        ORDER BY timestampNS ASC, sequence ASC
                        LIMIT ?
                    )
                    ORDER BY timestampNS DESC, sequence DESC
                    """
                    arguments.append(MacFSWSQLValue(visibleCount))
                } else {
                    snapshotSQL = """
                    INSERT INTO result_rows (snapshotID, rowIndex, eventID, sequence)
                    SELECT ?, ROW_NUMBER() OVER (ORDER BY timestampNS DESC, sequence DESC) - 1, id, sequence
                    FROM events
                    WHERE \(compiled.whereSQL)
                    ORDER BY timestampNS DESC, sequence DESC
                    """
                }
            }
            try db.execute(sql: snapshotSQL, arguments: MacFSWSQLQueryCompiler.arguments(arguments))
            return MacFSWEventResultSnapshot(id: snapshotID, totalCount: total, visibleCount: visibleCount)
        }
    }

    public func deleteResultSnapshot(_ snapshotID: String) async throws {
        try await deleteResultSnapshots([snapshotID])
    }

    public func deleteResultSnapshots(_ snapshotIDs: [String]) async throws {
        let snapshotIDs = Array(Set(snapshotIDs)).filter { !$0.isEmpty }
        guard !snapshotIDs.isEmpty else {
            return
        }
        try await dbQueue.write { db in
            for snapshotID in snapshotIDs {
                try db.execute(sql: "DELETE FROM result_snapshots WHERE id = ?", arguments: [snapshotID])
            }
        }
    }

    public func rowSummaries(
        in snapshot: MacFSWEventResultSnapshot,
        visibleRange: Range<Int>
    ) async throws -> [MacFSWEventRowSummary] {
        let lowerBound = max(0, min(snapshot.visibleCount, visibleRange.lowerBound))
        let upperBound = max(lowerBound, min(snapshot.visibleCount, visibleRange.upperBound))
        guard lowerBound < upperBound else {
            return []
        }
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT e.id, e.sequence, e.timestampNS, e.eventType, e.operationClass, e.risk,
                       e.processName, e.pid, e.targetPath, e.sourcePath, e.detailSummary,
                       e.signingID, e.teamID
                FROM result_rows r
                JOIN events e ON e.id = r.eventID
                WHERE r.snapshotID = ? AND r.rowIndex >= ? AND r.rowIndex < ?
                ORDER BY r.rowIndex ASC
                """,
                arguments: [snapshot.id, lowerBound, upperBound]
            )
            return rows.map(rowSummary(from:))
        }
    }

    public func event(
        in snapshot: MacFSWEventResultSnapshot,
        visibleRow: Int
    ) async throws -> MacFSWFileEvent? {
        guard visibleRow >= 0, visibleRow < snapshot.visibleCount else {
            return nil
        }
        return try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT e.*
                FROM result_rows r
                JOIN events e ON e.id = r.eventID
                WHERE r.snapshotID = ? AND r.rowIndex = ?
                LIMIT 1
                """,
                arguments: [snapshot.id, visibleRow]
            ) else {
                return nil
            }
            return try eventRecord(from: row)
        }
    }

    public func visibleRowIndex(
        of id: UUID,
        in snapshot: MacFSWEventResultSnapshot
    ) async throws -> Int? {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT rowIndex FROM result_rows WHERE snapshotID = ? AND eventID = ? LIMIT 1",
                arguments: [snapshot.id, id.uuidString]
            )
        }
    }

    public func appendRowsToResultSnapshot(
        _ snapshot: MacFSWEventResultSnapshot,
        rows: [MacFSWEventRowSummary],
        limit: Int
    ) async throws -> MacFSWEventResultSnapshot {
        guard !rows.isEmpty else {
            return snapshot
        }
        let hasVisibleLimit = limit > 0
        let visibleLimit = hasVisibleLimit ? limit : Int.max
        let appended = hasVisibleLimit ? Array(rows.suffix(visibleLimit)) : rows
        return try await dbQueue.write { db in
            let stored = try Row.fetchOne(
                db,
                sql: "SELECT totalCount, visibleCount FROM result_snapshots WHERE id = ?",
                arguments: [snapshot.id]
            )
            let currentTotal: Int = stored?["totalCount"] ?? snapshot.totalCount
            let currentVisible: Int = stored?["visibleCount"] ?? snapshot.visibleCount
            let overflow = hasVisibleLimit ? max(0, currentVisible + appended.count - visibleLimit) : 0
            if hasVisibleLimit, appended.count >= visibleLimit {
                try db.execute(sql: "DELETE FROM result_rows WHERE snapshotID = ?", arguments: [snapshot.id])
            } else if overflow > 0 {
                try db.execute(
                    sql: "DELETE FROM result_rows WHERE snapshotID = ? AND rowIndex < ?",
                    arguments: [snapshot.id, overflow]
                )
                try db.execute(
                    sql: "UPDATE result_rows SET rowIndex = rowIndex - ? WHERE snapshotID = ?",
                    arguments: [overflow, snapshot.id]
                )
            }

            let baseIndex = hasVisibleLimit && appended.count >= visibleLimit ? 0 : max(0, currentVisible - overflow)
            for (offset, row) in appended.enumerated() {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO result_rows (snapshotID, rowIndex, eventID, sequence)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [snapshot.id, baseIndex + offset, row.id.uuidString, Int64(row.sequence)]
                )
            }

            let nextTotal = currentTotal + rows.count
            let nextVisible = hasVisibleLimit ? min(visibleLimit, currentVisible + rows.count) : currentVisible + rows.count
            try db.execute(
                sql: "UPDATE result_snapshots SET totalCount = ?, visibleCount = ? WHERE id = ?",
                arguments: [nextTotal, nextVisible, snapshot.id]
            )
            return MacFSWEventResultSnapshot(id: snapshot.id, totalCount: nextTotal, visibleCount: nextVisible)
        }
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

    public func rowSummaries(
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
        SELECT id, sequence, timestampNS, eventType, operationClass, risk,
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
            return rows.map(rowSummary(from:))
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

    public func events(
        matching query: MacFSWEventQuery,
        sortOrder: MacFSWEventSortOrder = .oldestFirst,
        limit: Int = 0
    ) async throws -> [MacFSWFileEvent] {
        let compiled = MacFSWSQLQueryCompiler.compile(query)
        var arguments = compiled.arguments
        let sql: String
        if limit > 0 {
            arguments.append(MacFSWSQLValue(limit))
            sql = """
            SELECT *
            FROM events
            WHERE \(compiled.whereSQL)
            ORDER BY \(MacFSWSQLQueryCompiler.orderClause(sortOrder))
            LIMIT ?
            """
        } else {
            sql = """
            SELECT *
            FROM events
            WHERE \(compiled.whereSQL)
            ORDER BY \(MacFSWSQLQueryCompiler.orderClause(sortOrder))
            """
        }
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

    public func event(
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

    public func processSummaries() async throws -> [MacFSWProcessEventSummary] {
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
        GROUP BY pid
        ORDER BY lastEventNS DESC
        """

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql)
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
            return rows.map(operationEventSummary(from:))
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

    public func visibleRowIndex(
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

    public func snapshot() async throws -> [MacFSWFileEvent] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM events ORDER BY sequence ASC"
            )
            return try rows.map(eventRecord(from:))
        }
    }

    public func stats() async throws -> MacFSWCaptureStats {
        try await dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events") ?? 0
            let lastTimestamp = try Int64.fetchOne(
                db,
                sql: "SELECT timestampNS FROM events ORDER BY sequence DESC LIMIT 1"
            )
            return MacFSWCaptureStats(
                deliveredEvents: UInt64(count),
                droppedEvents: 0,
                queuedEvents: 0,
                lastEventAt: lastTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000_000) }
            )
        }
    }

    public func saveSessionMetadata(_ session: MacFSWResearchSession) async throws {
        var session = session
        session.metadata.updatedAt = Date()
        let sessionID = session.id.uuidString
        let name = session.name
        let targetDescription = session.targetDescription
        let schemaVersion = session.metadata.schemaVersion
        let appVersion = session.metadata.appVersion
        let createdAt = session.metadata.createdAt.timeIntervalSince1970
        let updatedAt = session.metadata.updatedAt.timeIntervalSince1970
        let source = session.metadata.source.rawValue
        let captureConfigJSON = String(data: try JSONEncoder.macfsw.encode(session.captureConfig), encoding: .utf8) ?? "{}"
        let savedQueriesJSON = String(data: try JSONEncoder.macfsw.encode(session.savedQueries), encoding: .utf8) ?? "[]"
        let markers = session.markers
        let annotations = session.annotations

        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM session")
            try db.execute(
                sql: """
                INSERT INTO session (
                    id, name, targetDescription, schemaVersion, appVersion,
                    createdAt, updatedAt, source, captureConfigJSON, savedQueriesJSON
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    sessionID,
                    name,
                    targetDescription,
                    schemaVersion,
                    appVersion,
                    createdAt,
                    updatedAt,
                    source,
                    captureConfigJSON,
                    savedQueriesJSON,
                ]
            )

            try db.execute(sql: "DELETE FROM markers")
            for marker in markers {
                try db.execute(
                    sql: "INSERT INTO markers (id, timestampNS, title, note) VALUES (?, ?, ?, ?)",
                    arguments: [
                        marker.id.uuidString,
                        Int64(marker.timestampNS),
                        marker.title,
                        marker.note,
                    ]
                )
            }

            try db.execute(sql: "DELETE FROM annotations")
            for annotation in annotations {
                try db.execute(
                    sql: """
                    INSERT INTO annotations (id, eventID, tag, note, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        annotation.id.uuidString,
                        annotation.eventID.uuidString,
                        annotation.tag,
                        annotation.note,
                        annotation.createdAt.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    public func sessionMetadata() async throws -> MacFSWResearchSession {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM session LIMIT 1") else {
                throw MacFSWSQLiteStoreError.missingSessionMetadata
            }

            let captureConfigJSON: String = row["captureConfigJSON"]
            let savedQueriesJSON: String = row["savedQueriesJSON"]
            let captureConfig = try JSONDecoder.macfsw.decode(
                MacFSWCaptureConfig.self,
                from: Data(captureConfigJSON.utf8)
            )
            let savedQueries = try JSONDecoder.macfsw.decode(
                [MacFSWSavedQuery].self,
                from: Data(savedQueriesJSON.utf8)
            )
            let markers = try Row.fetchAll(db, sql: "SELECT * FROM markers ORDER BY timestampNS ASC")
                .map(marker(from:))
            let annotations = try Row.fetchAll(db, sql: "SELECT * FROM annotations ORDER BY createdAt ASC")
                .map(annotation(from:))

            let idText: String = row["id"]
            let sourceText: String = row["source"]
            let schemaVersion: Int = row["schemaVersion"]
            let appVersion: String = row["appVersion"]
            let createdAt: Double = row["createdAt"]
            let updatedAt: Double = row["updatedAt"]
            return MacFSWResearchSession(
                id: UUID(uuidString: idText) ?? UUID(),
                name: row["name"],
                targetDescription: row["targetDescription"],
                captureConfig: captureConfig,
                metadata: MacFSWSessionMetadata(
                    schemaVersion: schemaVersion,
                    appVersion: appVersion,
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    updatedAt: Date(timeIntervalSince1970: updatedAt),
                    source: MacFSWSessionSource(rawValue: sourceText) ?? .live
                ),
                markers: markers,
                annotations: annotations,
                savedQueries: savedQueries
            )
        }
    }

    public func copyDatabase(to destinationURL: URL) async throws {
        guard !url.path.isEmpty else {
            throw MacFSWSQLiteStoreError.invalidDatabasePath
        }
        if url.standardizedFileURL == destinationURL.standardizedFileURL {
            return
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let escapedPath = destinationURL.path.replacingOccurrences(of: "'", with: "''")
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO '\(escapedPath)'")
        }
    }

    private static func insert(_ event: MacFSWFileEvent, db: Database) throws {
        let riskReasonsText = event.riskReasons.joined(separator: " ")
        let sourcePath = event.sourcePath
        let signingID = event.process.signingID
        let teamID = event.process.teamID
        let cdhash = event.process.cdhash
        let parameterText = event.parameterText
        let detailSummary = event.operationDetailSummary
        let sourceTextValues = [
            event.eventType.rawValue,
            event.operationClass.rawValue,
            event.targetPath,
            sourcePath,
            parameterText,
            detailSummary,
            event.process.processName,
            String(event.process.pid),
            event.process.executablePath,
            signingID,
            teamID,
            event.process.isPlatformBinary ? "true yes 1 on" : "false no 0 off",
            event.risk.rawValue,
            riskReasonsText,
            String(event.uid),
            String(event.gid),
            "\(event.uid)/\(event.gid)",
            event.id.uuidString,
            String(event.sequence),
            String(event.timestampNS),
            event.rawEventType,
            event.rawEventTypeValue.map { String($0) },
            String(event.rawEventVersion),
            String(event.flags),
            event.process.auditToken,
            cdhash,
        ].compactMap { $0 }.joined(separator: " ")
        let flagsText = String(event.flags)
        let fileIDText = event.fileID.map(String.init)
        let riskReasonsJSON = String(data: try JSONEncoder.macfsw.encode(event.riskReasons), encoding: .utf8) ?? "[]"
        let parametersJSON = String(data: try JSONEncoder.macfsw.encode(event.parameters), encoding: .utf8) ?? "[]"
        let appleControlled = event.process.isAppleControlledForStorage
        let sensitive = MacFSWRiskClassifier.isSensitivePath(event.targetPath)

        try db.execute(
            sql: """
            INSERT INTO events (
                id, sequence, timestampNS, eventType, operationClass, risk, riskScore,
                riskReasonsJSON, riskReasonsText, pid, pidText, auditToken, executablePath,
                processName, signingID, teamID, cdhash, isPlatformBinary,
                isPlatformBinaryText, appleControlled, appleControlledText,
                targetPath, sourcePath, parameterText, detailSummary, parametersJSON,
                fileIDText, flagsText, flagsHexText,
                uid, uidText, gid, gidText, uidGidText, rawEventType,
                rawEventTypeValue, rawEventTypeValueText, rawEventVersion,
                rawEventVersionText, sequenceText, timestampText,
                mutation, mutationText, sensitive, sensitiveText
            )
            VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            )
            """,
            arguments: [
                event.id.uuidString,
                Int64(event.sequence),
                Int64(event.timestampNS),
                event.eventType.rawValue,
                event.operationClass.rawValue,
                event.risk.rawValue,
                event.risk.score,
                riskReasonsJSON,
                riskReasonsText,
                Int(event.process.pid),
                String(event.process.pid),
                event.process.auditToken,
                event.process.executablePath,
                event.process.processName,
                signingID,
                teamID,
                cdhash,
                event.process.isPlatformBinary ? 1 : 0,
                event.process.isPlatformBinary.queryTextForStorage,
                appleControlled ? 1 : 0,
                appleControlled.queryTextForStorage,
                event.targetPath,
                sourcePath,
                parameterText,
                detailSummary,
                parametersJSON,
                fileIDText,
                flagsText,
                "0x" + String(event.flags, radix: 16),
                Int(event.uid),
                String(event.uid),
                Int(event.gid),
                String(event.gid),
                "\(event.uid)/\(event.gid)",
                event.rawEventType,
                event.rawEventTypeValue.map { Int($0) },
                event.rawEventTypeValue.map { String($0) } ?? "",
                Int(event.rawEventVersion),
                String(event.rawEventVersion),
                String(event.sequence),
                String(event.timestampNS),
                event.eventType.isMutation ? 1 : 0,
                event.eventType.isMutation.queryTextForStorage,
                sensitive ? 1 : 0,
                sensitive.queryTextForStorage,
            ]
        )

        try db.execute(
            sql: """
            INSERT INTO event_fts (
                rowid, any_text, process_text, executable_text, path_text,
                signing_text, team_text, risk_reason_text
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                Int64(event.sequence),
                sourceTextValues,
                event.process.processName,
                event.process.executablePath,
                [event.targetPath, sourcePath].compactMap { $0 }.joined(separator: " "),
                signingID ?? "",
                teamID ?? "",
                riskReasonsText,
            ]
        )
    }

    private static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("create_v1") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS session (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                targetDescription TEXT NOT NULL,
                schemaVersion INTEGER NOT NULL,
                appVersion TEXT NOT NULL,
                createdAt REAL NOT NULL,
                updatedAt REAL NOT NULL,
                source TEXT NOT NULL,
                captureConfigJSON TEXT NOT NULL,
                savedQueriesJSON TEXT NOT NULL
            )
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS markers (
                id TEXT PRIMARY KEY NOT NULL,
                timestampNS INTEGER NOT NULL,
                title TEXT NOT NULL,
                note TEXT NOT NULL
            )
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS annotations (
                id TEXT PRIMARY KEY NOT NULL,
                eventID TEXT NOT NULL,
                tag TEXT NOT NULL,
                note TEXT NOT NULL,
                createdAt REAL NOT NULL
            )
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS events (
                id TEXT NOT NULL UNIQUE,
                sequence INTEGER PRIMARY KEY NOT NULL,
                timestampNS INTEGER NOT NULL,
                eventType TEXT NOT NULL,
                operationClass TEXT NOT NULL,
                risk TEXT NOT NULL,
                riskScore INTEGER NOT NULL,
                riskReasonsJSON TEXT NOT NULL,
                riskReasonsText TEXT NOT NULL,
                pid INTEGER NOT NULL,
                pidText TEXT NOT NULL,
                auditToken TEXT NOT NULL,
                executablePath TEXT NOT NULL,
                processName TEXT NOT NULL,
                signingID TEXT,
                teamID TEXT,
                cdhash TEXT,
                isPlatformBinary INTEGER NOT NULL,
                isPlatformBinaryText TEXT NOT NULL,
                appleControlled INTEGER NOT NULL,
                appleControlledText TEXT NOT NULL,
                targetPath TEXT NOT NULL,
                sourcePath TEXT,
                parameterText TEXT NOT NULL,
                detailSummary TEXT NOT NULL,
                parametersJSON TEXT NOT NULL,
                fileIDText TEXT,
                flagsText TEXT NOT NULL,
                flagsHexText TEXT NOT NULL,
                uid INTEGER NOT NULL,
                uidText TEXT NOT NULL,
                gid INTEGER NOT NULL,
                gidText TEXT NOT NULL,
                uidGidText TEXT NOT NULL,
                rawEventType TEXT NOT NULL,
                rawEventTypeValue INTEGER,
                rawEventTypeValueText TEXT NOT NULL,
                rawEventVersion INTEGER NOT NULL,
                rawEventVersionText TEXT NOT NULL,
                sequenceText TEXT NOT NULL,
                timestampText TEXT NOT NULL,
                mutation INTEGER NOT NULL,
                mutationText TEXT NOT NULL,
                sensitive INTEGER NOT NULL,
                sensitiveText TEXT NOT NULL
            )
            """)

            try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS event_fts USING fts5(
                any_text,
                process_text,
                executable_text,
                path_text,
                signing_text,
                team_text,
                risk_reason_text,
                tokenize = 'unicode61'
            )
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS result_snapshots (
                id TEXT PRIMARY KEY NOT NULL,
                createdAt REAL NOT NULL,
                totalCount INTEGER NOT NULL,
                visibleCount INTEGER NOT NULL
            )
            """)

            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS result_rows (
                snapshotID TEXT NOT NULL,
                rowIndex INTEGER NOT NULL,
                eventID TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                PRIMARY KEY (snapshotID, rowIndex),
                FOREIGN KEY (snapshotID) REFERENCES result_snapshots(id) ON DELETE CASCADE
            )
            """)

            for indexSQL in baseIndexSQL + largeFilterIndexSQL {
                try db.execute(sql: indexSQL)
            }
        }
        migrator.registerMigration("add_process_filter_indexes_v2") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_pid_audit_time ON events(pid, auditToken, timestampNS, sequence)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_pid_executable_time ON events(pid, executablePath, timestampNS, sequence)")
        }
        migrator.registerMigration("add_result_snapshots_v3") { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS result_snapshots (
                id TEXT PRIMARY KEY NOT NULL,
                createdAt REAL NOT NULL,
                totalCount INTEGER NOT NULL,
                visibleCount INTEGER NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS result_rows (
                snapshotID TEXT NOT NULL,
                rowIndex INTEGER NOT NULL,
                eventID TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                PRIMARY KEY (snapshotID, rowIndex),
                FOREIGN KEY (snapshotID) REFERENCES result_snapshots(id) ON DELETE CASCADE
            )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_result_rows_event ON result_rows(snapshotID, eventID)")
        }
        migrator.registerMigration("add_event_parameters_v4") { db in
            let existingColumns = Set(try db.columns(in: "events").map(\.name))
            if !existingColumns.contains("parameterText") {
                try db.execute(sql: "ALTER TABLE events ADD COLUMN parameterText TEXT NOT NULL DEFAULT ''")
            }
            if !existingColumns.contains("detailSummary") {
                try db.execute(sql: "ALTER TABLE events ADD COLUMN detailSummary TEXT NOT NULL DEFAULT ''")
            }
            if !existingColumns.contains("parametersJSON") {
                try db.execute(sql: "ALTER TABLE events ADD COLUMN parametersJSON TEXT NOT NULL DEFAULT '[]'")
            }
        }
        migrator.registerMigration("add_large_filter_indexes_v5") { db in
            for indexSQL in largeFilterIndexSQL {
                try db.execute(sql: indexSQL)
            }
        }
        migrator.registerMigration("add_raw_event_type_value_v6") { db in
            let existingColumns = Set(try db.columns(in: "events").map(\.name))
            if !existingColumns.contains("rawEventTypeValue") {
                try db.execute(sql: "ALTER TABLE events ADD COLUMN rawEventTypeValue INTEGER")
            }
            if !existingColumns.contains("rawEventTypeValueText") {
                try db.execute(sql: "ALTER TABLE events ADD COLUMN rawEventTypeValueText TEXT NOT NULL DEFAULT ''")
            }
        }
        try migrator.migrate(dbQueue)
    }

    private static func readNextSequence(_ dbQueue: DatabaseQueue) throws -> UInt64 {
        try dbQueue.read { db in
            let maxSequence = try Int64.fetchOne(db, sql: "SELECT MAX(sequence) FROM events") ?? 0
            return UInt64(max(0, maxSequence)) + 1
        }
    }

    private static func ensureSession(_ session: MacFSWResearchSession, dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session") ?? 0
            guard count == 0 else {
                return
            }
            try db.execute(
                sql: """
                INSERT INTO session (
                    id, name, targetDescription, schemaVersion, appVersion,
                    createdAt, updatedAt, source, captureConfigJSON, savedQueriesJSON
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    session.id.uuidString,
                    session.name,
                    session.targetDescription,
                    session.metadata.schemaVersion,
                    session.metadata.appVersion,
                    session.metadata.createdAt.timeIntervalSince1970,
                    session.metadata.updatedAt.timeIntervalSince1970,
                    session.metadata.source.rawValue,
                    String(data: try JSONEncoder.macfsw.encode(session.captureConfig), encoding: .utf8) ?? "{}",
                    String(data: try JSONEncoder.macfsw.encode(session.savedQueries), encoding: .utf8) ?? "[]",
                ]
            )
        }
    }

    private static func validateSQLiteHeader(at url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count >= 16 else {
            throw MacFSWSQLiteStoreError.unsupportedFormat(url)
        }
        let header = String(decoding: data.prefix(16), as: UTF8.self)
        guard header == "SQLite format 3\u{0000}" else {
            throw MacFSWSQLiteStoreError.unsupportedFormat(url)
        }
    }
}

private func rowSummary(from row: Row) -> MacFSWEventRowSummary {
    let idText: String = row["id"]
    let sequence: Int64 = row["sequence"]
    let timestampNS: Int64 = row["timestampNS"]
    let eventTypeText: String = row["eventType"]
    let operationClassText: String = row["operationClass"]
    let riskText: String = row["risk"]
    let signingID: String? = row["signingID"]
    let teamID: String? = row["teamID"]
    return MacFSWEventRowSummary(
        id: UUID(uuidString: idText) ?? UUID(),
        sequence: UInt64(sequence),
        timestampNS: UInt64(timestampNS),
        eventType: MacFSWEventType(rawValue: eventTypeText) ?? .unknown,
        operationClass: MacFSWOperationClass(rawValue: operationClassText) ?? .unknown,
        risk: MacFSWRiskLevel(rawValue: riskText) ?? .low,
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
        uid: UInt32(max(0, uid)),
        gid: UInt32(max(0, gid)),
        eventCount: row["eventCount"],
        lastEventNS: UInt64(max(0, lastEventNS)),
        isPlatformBinary: isPlatformBinary != 0,
        identityCount: row["identityCount"] ?? 1
    )
}

private func operationEventSummary(from row: Row) -> MacFSWOperationEventSummary {
    let eventTypeText: String = row["eventType"]
    let operationClassText: String = row["operationClass"]
    let eventCount: Int = row["eventCount"]
    return MacFSWOperationEventSummary(
        eventType: MacFSWEventType(rawValue: eventTypeText) ?? .unknown,
        operationClass: MacFSWOperationClass(rawValue: operationClassText) ?? .unknown,
        eventCount: eventCount
    )
}

private func eventRecord(from row: Row) throws -> MacFSWFileEvent {
    let idText: String = row["id"]
    let sequence: Int64 = row["sequence"]
    let timestampNS: Int64 = row["timestampNS"]
    let eventTypeText: String = row["eventType"]
    let operationClassText: String = row["operationClass"]
    let riskText: String = row["risk"]
    let riskReasonsJSON: String = row["riskReasonsJSON"]
    let riskReasons = try JSONDecoder.macfsw.decode([String].self, from: Data(riskReasonsJSON.utf8))
    let parametersJSON: String = row["parametersJSON"]
    let parameters = (try? JSONDecoder.macfsw.decode([MacFSWEventParameter].self, from: Data(parametersJSON.utf8))) ?? []
    let fileIDText: String? = row["fileIDText"]
    let flagsText: String = row["flagsText"]
    let rawEventTypeValue: Int? = row["rawEventTypeValue"]
    let rawEventVersion: Int = row["rawEventVersion"]

    return MacFSWFileEvent(
        id: UUID(uuidString: idText) ?? UUID(),
        sequence: UInt64(sequence),
        timestampNS: UInt64(timestampNS),
        eventType: MacFSWEventType(rawValue: eventTypeText) ?? .unknown,
        operationClass: MacFSWOperationClass(rawValue: operationClassText) ?? .unknown,
        risk: MacFSWRiskLevel(rawValue: riskText) ?? .low,
        riskReasons: riskReasons,
        process: MacFSWProcessIdentity(
            pid: Int32(row["pid"] as Int),
            auditToken: row["auditToken"],
            executablePath: row["executablePath"],
            processName: row["processName"],
            signingID: row["signingID"],
            teamID: row["teamID"],
            cdhash: row["cdhash"],
            isPlatformBinary: (row["isPlatformBinary"] as Int) != 0
        ),
        targetPath: row["targetPath"],
        sourcePath: row["sourcePath"],
        parameters: parameters,
        fileID: fileIDText.flatMap(UInt64.init),
        flags: UInt64(flagsText) ?? 0,
        uid: UInt32(row["uid"] as Int),
        gid: UInt32(row["gid"] as Int),
        rawEventType: row["rawEventType"],
        rawEventTypeValue: rawEventTypeValue.map { UInt32($0) },
        rawEventVersion: UInt32(rawEventVersion)
    )
}

private func marker(from row: Row) -> MacFSWMarker {
    let idText: String = row["id"]
    let timestampNS: Int64 = row["timestampNS"]
    return MacFSWMarker(
        id: UUID(uuidString: idText) ?? UUID(),
        timestampNS: UInt64(timestampNS),
        title: row["title"],
        note: row["note"]
    )
}

private func annotation(from row: Row) -> MacFSWAnnotation {
    let idText: String = row["id"]
    let eventIDText: String = row["eventID"]
    let createdAt: Double = row["createdAt"]
    return MacFSWAnnotation(
        id: UUID(uuidString: idText) ?? UUID(),
        eventID: UUID(uuidString: eventIDText) ?? UUID(),
        tag: row["tag"],
        note: row["note"],
        createdAt: Date(timeIntervalSince1970: createdAt)
    )
}

private extension MacFSWProcessIdentity {
    var isAppleControlledForStorage: Bool {
        if isPlatformBinary {
            return true
        }
        if let signingID, signingID.lowercased().hasPrefix("com.apple.") {
            return true
        }
        return false
    }
}

private extension Bool {
    var queryTextForStorage: String {
        self ? "true yes 1 on" : "false no 0 off"
    }
}
