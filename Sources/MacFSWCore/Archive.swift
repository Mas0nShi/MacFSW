import Foundation

public enum MacFSWArchiveError: Error, LocalizedError, Sendable {
    case unsupportedFormat(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let url):
            "\(url.lastPathComponent) is not a session file this version of MacFSW can open."
        }
    }
}

public enum MacFSWSessionArchive {
    public static let nativeExtension = "macfsw-session"

    /// Writes `session` and every event in `store` to a new file at `url`.
    /// A read-only store is copied first and the copy takes the metadata,
    /// so the opened file stays untouched.
    public static func saveSession(
        _ session: MacFSWResearchSession,
        from store: MacFSWSQLiteEventStore,
        to url: URL
    ) async throws {
        if store.isReadOnly {
            try await store.copyDatabase(to: url)
            try await MacFSWSQLiteEventStore(url: url).saveSessionMetadata(session)
        } else {
            try await store.saveSessionMetadata(session)
            try await store.copyDatabase(to: url)
        }
    }

    /// Opens a saved session read-only; files from other MacFSW schema
    /// versions are rejected.
    public static func openSessionStore(from url: URL) throws -> MacFSWSQLiteEventStore {
        do {
            return try MacFSWSQLiteEventStore.openReadOnly(url)
        } catch MacFSWSQLiteStoreError.unsupportedFormat {
            throw MacFSWArchiveError.unsupportedFormat(url)
        }
    }
}

public extension JSONEncoder {
    static var macfsw: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var macfswPretty: JSONEncoder {
        let encoder = JSONEncoder.macfsw
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public extension JSONDecoder {
    static var macfsw: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
