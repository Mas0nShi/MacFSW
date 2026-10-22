import Foundation
import GRDB

public enum MacFSWSQLiteStoreError: Error, LocalizedError, Sendable {
    case unsupportedFormat(URL)
    case missingSessionMetadata
    case unexpectedValue(column: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let url):
            "Unsupported MacFSW SQLite format: \(url.lastPathComponent)."
        case .missingSessionMetadata:
            "The MacFSW database is missing session metadata."
        case .unexpectedValue(let column, let value):
            "The session holds an unexpected \(column) value \"\(value)\"; it was not written by this version of MacFSW."
        }
    }
}

public actor MacFSWSQLiteEventStore {
    public nonisolated let url: URL
    public nonisolated let isReadOnly: Bool
    let dbQueue: DatabaseQueue
    private let ownedDirectoryURL: URL?
    private let ownerLock: TemporaryDirectoryLock?
    private var nextSequence: UInt64
    private var didCleanupBackingStore = false
    var resultSnapshots: [String: StoredResultSnapshot] = [:]
    private static let temporaryDirectoryPrefix = "macfsw-"
    public init(url: URL, defaultSession: MacFSWResearchSession = MacFSWResearchSession()) throws {
        try self.init(url: url, mode: .writable(defaultSession), ownedDirectoryURL: nil, ownerLock: nil)
    }

    /// Opens a saved session without ever writing to it. Files that do not
    /// carry the current schema are rejected rather than upgraded.
    public static func openReadOnly(_ url: URL) throws -> MacFSWSQLiteEventStore {
        try MacFSWSQLiteEventStore(url: url, mode: .readOnly, ownedDirectoryURL: nil, ownerLock: nil)
    }

    private enum Mode {
        case writable(MacFSWResearchSession)
        case readOnly
    }

    private init(url: URL, mode: Mode, ownedDirectoryURL: URL?, ownerLock: TemporaryDirectoryLock?) throws {
        self.url = url
        self.ownedDirectoryURL = ownedDirectoryURL
        self.ownerLock = ownerLock

        var configuration = Configuration()
        let isTemporary = ownedDirectoryURL != nil
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            if isTemporary {
                // A temporary store is discarded after a crash anyway, so it
                // skips durability work. Not WAL: that mode is stored in the
                // file header and would make saved copies unopenable read-only.
                try db.execute(sql: "PRAGMA journal_mode = MEMORY")
                try db.execute(sql: "PRAGMA synchronous = OFF")
            }
        }
        switch mode {
        case .writable(let session):
            isReadOnly = false
            dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
            try Self.migrate(dbQueue)
            try Self.ensureSession(session, dbQueue: dbQueue)
        case .readOnly:
            isReadOnly = true
            configuration.readonly = true
            do {
                dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
                guard try Self.hasCurrentSchema(dbQueue) else {
                    throw MacFSWSQLiteStoreError.unsupportedFormat(url)
                }
            } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
                // Not an SQLite file at all.
                throw MacFSWSQLiteStoreError.unsupportedFormat(url)
            }
        }
        nextSequence = try Self.readNextSequence(dbQueue)
    }

    public static func temporary(session: MacFSWResearchSession = MacFSWResearchSession()) throws -> MacFSWSQLiteEventStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(temporaryDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try TemporaryDirectoryLock(holding: directory)
        return try MacFSWSQLiteEventStore(
            url: directory.appendingPathComponent("session.sqlite"),
            mode: .writable(session),
            ownedDirectoryURL: directory,
            ownerLock: lock
        )
    }

    /// Deletes temporary stores left behind by processes that exited without
    /// cleaning up. Stores still locked by a live process — another app
    /// instance or a running `macfsw` CLI — are left alone.
    public static func cleanupStaleTemporaryStores() throws {
        let fileManager = FileManager.default
        let directoryURLs = try fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directoryURL in directoryURLs where isManagedTemporaryDirectoryName(directoryURL.lastPathComponent) {
            let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true, !TemporaryDirectoryLock.isHeld(in: directoryURL) else {
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
        ownerLock?.release()
        if FileManager.default.fileExists(atPath: ownedDirectoryURL.path) {
            try FileManager.default.removeItem(at: ownedDirectoryURL)
        }
    }

    public func appendReturningEvents(_ incoming: [MacFSWFileEvent]) async throws -> MacFSWEventAppendResult {
        let sequenced = try await dbQueue.write { db in
            let databaseNextSequence = try Self.readNextSequence(db)
            var sequence = databaseNextSequence
            var eventsToInsert = incoming
            for index in eventsToInsert.indices {
                eventsToInsert[index].sequence = sequence
                sequence += 1
            }
            for event in eventsToInsert {
                try Self.insert(event, db: db)
            }
            return eventsToInsert
        }
        nextSequence = (sequenced.last?.sequence ?? (nextSequence - 1)) + 1

        // Sequences start at 1 and only `clear()` deletes (resetting them), so
        // the count is known without scanning the table on every batch.
        let stats = MacFSWCaptureStats(
            deliveredEvents: nextSequence - 1,
            lastEventAt: sequenced.last.map { Date(timeIntervalSince1970: TimeInterval($0.timestampNS) / 1_000_000_000) }
        )
        return MacFSWEventAppendResult(events: sequenced, stats: stats)
    }

    public func clear() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM event_fts")
            try db.execute(sql: "DELETE FROM events")
        }
        resultSnapshots.removeAll(keepingCapacity: true)
        nextSequence = 1
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
        let captureConfigJSON = String(decoding: try JSONEncoder.macfsw.encode(session.captureConfig), as: UTF8.self)
        let savedQueriesJSON = String(decoding: try JSONEncoder.macfsw.encode(session.savedQueries), as: UTF8.self)
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
            let annotations = try Row.fetchAll(db, sql: "SELECT * FROM annotations ORDER BY createdAt ASC")
                .map { try annotation(from: $0) }

            let schemaVersion: Int = row["schemaVersion"]
            let appVersion: String = row["appVersion"]
            let createdAt: Double = row["createdAt"]
            let updatedAt: Double = row["updatedAt"]
            return MacFSWResearchSession(
                id: try row.uuid("id"),
                name: row["name"],
                targetDescription: row["targetDescription"],
                captureConfig: captureConfig,
                metadata: MacFSWSessionMetadata(
                    schemaVersion: schemaVersion,
                    appVersion: appVersion,
                    createdAt: Date(timeIntervalSince1970: createdAt),
                    updatedAt: Date(timeIntervalSince1970: updatedAt),
                    source: try row.value("source")
                ),
                annotations: annotations,
                savedQueries: savedQueries
            )
        }
    }

    public func copyDatabase(to destinationURL: URL) async throws {
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

    private static func readNextSequence(_ dbQueue: DatabaseQueue) throws -> UInt64 {
        try dbQueue.read { db in
            try readNextSequence(db)
        }
    }

    private static func readNextSequence(_ db: Database) throws -> UInt64 {
        let maxSequence = try Int64.fetchOne(db, sql: "SELECT MAX(sequence) FROM events") ?? 0
        return UInt64(maxSequence) + 1
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
                    String(decoding: try JSONEncoder.macfsw.encode(session.captureConfig), as: UTF8.self),
                    String(decoding: try JSONEncoder.macfsw.encode(session.savedQueries), as: UTF8.self),
                ]
            )
        }
    }
}
