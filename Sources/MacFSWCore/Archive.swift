import Foundation

public enum MacFSWArchiveError: Error, LocalizedError, Sendable {
    case unsupportedFormat(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let url):
            "Unsupported MacFSW file format: \(url.lastPathComponent)."
        }
    }
}

public enum MacFSWSessionArchive {
    public static let nativeExtension = "macfsw-session"

    public static func saveSession(
        _ session: MacFSWResearchSession,
        from store: MacFSWSQLiteEventStore,
        to url: URL
    ) async throws {
        try await store.saveSessionMetadata(session)
        try await store.copyDatabase(to: url)
    }

    public static func openSessionStore(from url: URL) throws -> MacFSWSQLiteEventStore {
        do {
            return try MacFSWSQLiteEventStore(url: url, createIfNeeded: false)
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
