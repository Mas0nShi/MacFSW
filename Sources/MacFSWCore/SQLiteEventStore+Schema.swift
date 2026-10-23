import Foundation
import GRDB

extension MacFSWSQLiteEventStore {
    private static let baseIndexSQL = [
        "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestampNS)",
        "CREATE INDEX IF NOT EXISTS idx_events_type ON events(eventType)",
        "CREATE INDEX IF NOT EXISTS idx_events_operation_class ON events(operationClass)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid ON events(pid)",
        "CREATE INDEX IF NOT EXISTS idx_events_process_name ON events(processName)",
        "CREATE INDEX IF NOT EXISTS idx_events_signing ON events(signingID)",
        "CREATE INDEX IF NOT EXISTS idx_events_team ON events(teamID)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid_audit_time ON events(pid, auditToken, timestampNS, sequence)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid_executable_time ON events(pid, executablePath, timestampNS, sequence)",
    ]
    private static let largeFilterIndexSQL = [
        "CREATE INDEX IF NOT EXISTS idx_events_pid_time ON events(pid, timestampNS, sequence)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid_operation_class_time ON events(pid, operationClass, timestampNS, sequence)",
        "CREATE INDEX IF NOT EXISTS idx_events_pid_event_type_time ON events(pid, eventType, timestampNS, sequence)",
        "CREATE INDEX IF NOT EXISTS idx_events_operation_class_time ON events(operationClass, timestampNS, sequence)",
    ]

    /// Opens the store at `url` for writing, creating it — schema and
    /// session row — when it does not exist yet.
    static func insert(_ event: MacFSWFileEvent, db: Database) throws {
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
        let parametersJSON = String(decoding: try parametersEncoder.encode(event.parameters), as: UTF8.self)
        let appleControlled = event.process.isAppleControlledForStorage

        try db.cachedStatement(sql: """
            INSERT INTO events (
                id, sequence, timestampNS, eventType, operationClass,
                pid, pidText, auditToken, executablePath,
                processName, signingID, teamID, cdhash, isPlatformBinary,
                isPlatformBinaryText, appleControlled, appleControlledText,
                targetPath, sourcePath, parameterText, detailSummary, parametersJSON,
                fileIDText, flagsText, flagsHexText,
                uid, uidText, gid, gidText, uidGidText, rawEventType,
                rawEventTypeValue, rawEventTypeValueText, rawEventVersion,
                rawEventVersionText, sequenceText, timestampText,
                mutation, mutationText
            )
            VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            )
            """).execute(arguments: [
                event.id.uuidString,
                Int64(event.sequence),
                Int64(event.timestampNS),
                event.eventType.rawValue,
                event.operationClass.rawValue,
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
            ])

        try db.cachedStatement(sql: """
            INSERT INTO event_fts (
                rowid, any_text, process_text, executable_text, path_text,
                signing_text, team_text
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """).execute(arguments: [
                Int64(event.sequence),
                sourceTextValues,
                event.process.processName,
                event.process.executablePath,
                [event.targetPath, sourcePath].compactMap { $0 }.joined(separator: " "),
                signingID ?? "",
                teamID ?? "",
            ])
    }

    /// One encoder for every insert; `JSONEncoder.macfsw` builds a new one
    /// per access. Parameters carry no dates, so the strategy is irrelevant.
    private static let parametersEncoder = JSONEncoder()

    private static let schemaMigration = "create_v1"

    static func hasCurrentSchema(_ dbQueue: DatabaseQueue) throws -> Bool {
        try dbQueue.read { db in
            guard try db.tableExists("grdb_migrations") else {
                return false
            }
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            return applied == [schemaMigration]
        }
    }

    static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(schemaMigration) { db in
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
            CREATE TABLE IF NOT EXISTS annotations (
                id TEXT PRIMARY KEY NOT NULL,
                eventID TEXT NOT NULL,
                tag TEXT NOT NULL,
                note TEXT NOT NULL,
                createdAt REAL NOT NULL
            )
            """)

            try createEventTables(db)
        }
        try migrator.migrate(dbQueue)
    }

    /// The events table, its full-text index, and the indexes queries rely
    /// on. Also used by `clear()`, which drops and recreates them.
    static func createEventTables(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS events (
            id TEXT NOT NULL UNIQUE,
            sequence INTEGER PRIMARY KEY NOT NULL,
            timestampNS INTEGER NOT NULL,
            eventType TEXT NOT NULL,
            operationClass TEXT NOT NULL,
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
            mutationText TEXT NOT NULL
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
            tokenize = 'unicode61'
        )
        """)

        for indexSQL in baseIndexSQL + largeFilterIndexSQL {
            try db.execute(sql: indexSQL)
        }
    }
}

func eventRecord(from row: Row) throws -> MacFSWFileEvent {
    let sequence: Int64 = row["sequence"]
    let timestampNS: Int64 = row["timestampNS"]
    let parametersJSON: String = row["parametersJSON"]
    let fileIDText: String? = row["fileIDText"]
    let rawEventTypeValue: Int? = row["rawEventTypeValue"]
    let rawEventVersion: Int = row["rawEventVersion"]

    return MacFSWFileEvent(
        id: try row.uuid("id"),
        sequence: UInt64(sequence),
        timestampNS: UInt64(timestampNS),
        eventType: try row.value("eventType"),
        operationClass: try row.value("operationClass"),
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
        parameters: try JSONDecoder.macfsw.decode([MacFSWEventParameter].self, from: Data(parametersJSON.utf8)),
        fileID: fileIDText.flatMap(UInt64.init),
        flags: try row.number("flagsText"),
        uid: UInt32(row["uid"] as Int),
        gid: UInt32(row["gid"] as Int),
        rawEventType: row["rawEventType"],
        rawEventTypeValue: rawEventTypeValue.map { UInt32($0) },
        rawEventVersion: UInt32(rawEventVersion)
    )
}

func annotation(from row: Row) throws -> MacFSWAnnotation {
    let createdAt: Double = row["createdAt"]
    return MacFSWAnnotation(
        id: try row.uuid("id"),
        eventID: try row.uuid("eventID"),
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

/// Reading columns whose values the schema guarantees. A value that does
/// not parse means the file was not written by this version of MacFSW,
/// which is reported instead of being papered over with a default.
extension Row {
    func value<T: RawRepresentable>(_ column: String) throws -> T where T.RawValue == String {
        let text: String = self[column]
        guard let value = T(rawValue: text) else {
            throw MacFSWSQLiteStoreError.unexpectedValue(column: column, value: text)
        }
        return value
    }

    func uuid(_ column: String) throws -> UUID {
        let text: String = self[column]
        guard let value = UUID(uuidString: text) else {
            throw MacFSWSQLiteStoreError.unexpectedValue(column: column, value: text)
        }
        return value
    }

    func number(_ column: String) throws -> UInt64 {
        let text: String = self[column]
        guard let value = UInt64(text) else {
            throw MacFSWSQLiteStoreError.unexpectedValue(column: column, value: text)
        }
        return value
    }
}
