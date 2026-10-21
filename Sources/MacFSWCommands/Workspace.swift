import Foundation
import MacFSWCore

public enum CommandError: Error, LocalizedError, Equatable, Sendable {
    case noActiveSession
    case eventNotFound(UUID)
    case extensionUnavailable(String)
    case fileExists(String)
    case fileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            "No session is active. Start a capture or open a .macfsw-session file first."
        case .eventNotFound(let id):
            "No event with id \(id.uuidString) in the active session."
        case .extensionUnavailable(let message):
            "The MacFSW Endpoint Extension is not available: \(message) \(ExtensionInspector.setupHint)"
        case .fileNotFound(let path):
            "\(path) does not exist."
        case .fileExists(let path):
            "\(path) already exists. Choose another path or allow overwriting."
        }
    }
}

/// What to record, in the terms an operator or agent thinks in. Fields
/// left empty keep the capture profile's defaults.
public struct CaptureRequest: Codable, Equatable, Sendable {
    public var profile: MacFSWCaptureProfile = .focusedMutations
    public var durationSeconds: Int?
    public var targetPIDs: [Int32] = []
    public var targetProcessNames: [String] = []
    public var includePaths: [String] = []
    public var excludePaths: [String] = []
    public var excludeProcessNames: [String] = []

    public init() {}

    public var config: MacFSWCaptureConfig {
        var config = MacFSWCaptureConfig(profile: profile)
        if let durationSeconds {
            config.maxCaptureDurationSeconds = max(1, durationSeconds)
        }
        config.targetPIDs = targetPIDs
        config.targetProcessNames = targetProcessNames
        config.includePaths = includePaths
        config.excludePaths = excludePaths
        config.excludedProcessNames += excludeProcessNames
        return config
    }
}

/// The session an operator or agent is working with: at most one at a
/// time, either recorded here or opened from a file.
public actor Workspace {
    private struct Active {
        var capture: MacFSWCaptureSession
        var research: MacFSWResearchSession
        var source: SessionInfo.Source
        var path: URL?
    }

    private let client: any MacFSWCaptureClient
    private let appVersion: String
    private let inspector: ExtensionInspector
    private var active: Active?

    public init(
        client: any MacFSWCaptureClient,
        appVersion: String,
        inspector: ExtensionInspector = ExtensionInspector(bundledVersion: nil)
    ) {
        self.client = client
        self.appVersion = appVersion
        self.inspector = inspector
    }

    public func status() async -> Status {
        Status(extension: await inspector.inspect(client), session: try? await sessionInfo())
    }

    /// Starts recording. A session opened from a file is closed first so a
    /// saved artifact is never written to; a session this workspace
    /// recorded keeps growing.
    public func startCapture(_ request: CaptureRequest) async throws -> SessionInfo {
        if active == nil || active?.source == .file {
            try await replaceActive(with: newCaptureSession(config: request.config))
        }
        let session = try requireActive()
        do {
            try await session.capture.start(config: request.config)
        } catch let error as MacFSWClientError {
            throw CommandError.extensionUnavailable(error.userFacingMessage)
        }
        return try await sessionInfo()
    }

    public func stopCapture() async throws -> SessionInfo {
        try await requireActive().capture.stop()
        return try await sessionInfo()
    }

    public func open(_ url: URL) async throws -> SessionInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CommandError.fileNotFound(url.path)
        }
        let (capture, research) = try await MacFSWCaptureSession.open(url, client: client)
        try await replaceActive(with: Active(capture: capture, research: research, source: .file, path: url))
        return try await sessionInfo()
    }

    public func save(to url: URL, overwrite: Bool = false) async throws -> SessionInfo {
        let session = try requireActive()
        guard overwrite || !FileManager.default.fileExists(atPath: url.path) else {
            throw CommandError.fileExists(url.path)
        }
        var research = session.research
        research.metadata.updatedAt = Date()
        try await session.capture.save(research, to: url)
        return try await sessionInfo()
    }

    public func close() async throws {
        try await replaceActive(with: nil)
    }

    public func queries() throws -> SessionQueries {
        SessionQueries(store: try requireActive().capture.store)
    }

    public func sessionInfo() async throws -> SessionInfo {
        let session = try requireActive()
        let stats = await session.capture.stats
        return SessionInfo(
            name: session.research.name,
            source: session.source,
            path: session.path?.path,
            events: try await session.capture.store.count(matching: MacFSWEventQuery()),
            captureState: await session.capture.state,
            deliveredEvents: stats.deliveredEvents,
            droppedEvents: stats.droppedEvents
        )
    }

    private func newCaptureSession(config: MacFSWCaptureConfig) throws -> Active {
        let research = MacFSWResearchSession(
            name: "macfsw capture \(Date().formatted(.iso8601))",
            captureConfig: config,
            metadata: MacFSWSessionMetadata(appVersion: appVersion)
        )
        return Active(capture: try .temporary(for: research, client: client), research: research, source: .capture, path: nil)
    }

    private func replaceActive(with new: Active?) async throws {
        let old = active
        active = new
        try await old?.capture.close()
    }

    private func requireActive() throws -> Active {
        guard let active else {
            throw CommandError.noActiveSession
        }
        return active
    }
}
