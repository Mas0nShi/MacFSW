import Foundation
import MacFSWCore

public struct ExtensionStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case ready
        /// The activated extension is older than the one this MacFSW ships.
        case outdated
        case notInstalled
        case needsFullDiskAccess
        case notAuthorized
        case unreachable
    }

    public var state: State
    public var runningVersion: String?
    public var bundledVersion: String?
    public var message: String
}

/// Works out why recording is or is not possible. Only the app can install
/// or update the extension, so every non-ready answer says how to get it
/// there.
public struct ExtensionInspector: Sendable {
    public static let setupHint = "Run `macfsw setup` (or open the MacFSW app) to install or update it; macOS asks you to approve."

    /// The extension packaged with this MacFSW; nil outside a packaged app.
    public var bundledVersion: MacFSWComponentVersion?
    /// The version macOS has activated, for when the extension refuses the
    /// connection and cannot say for itself.
    public var activatedVersion: @Sendable () async -> MacFSWComponentVersion?

    public init(
        bundledVersion: MacFSWComponentVersion?,
        activatedVersion: @escaping @Sendable () async -> MacFSWComponentVersion? = { nil }
    ) {
        self.bundledVersion = bundledVersion
        self.activatedVersion = activatedVersion
    }

    public func inspect(_ client: any MacFSWCaptureClient) async -> ExtensionStatus {
        let health: MacFSWCaptureHealth
        do {
            health = try await client.health()
        } catch {
            return await unreachable(error)
        }

        let running = health.extensionVersion
        if let bundledVersion, running != bundledVersion {
            return status(.outdated, running: running, "The running Endpoint Extension (\(running?.description ?? "an older build")) is older than the one in this MacFSW (\(bundledVersion)). \(Self.setupHint)")
        }
        if health.fullDiskAccessHint {
            return status(.needsFullDiskAccess, running: running, "\(health.message) Grant Full Disk Access to MacFSW Endpoint Extension in System Settings > Privacy & Security.")
        }
        guard health.endpointSecurityAuthorized else {
            return status(.notAuthorized, running: running, "\(health.message) \(Self.setupHint)")
        }
        return status(.ready, running: running, health.message)
    }

    private func unreachable(_ error: any Error) async -> ExtensionStatus {
        let activated = await activatedVersion()
        if let bundledVersion, let activated, activated != bundledVersion {
            return status(.outdated, running: activated, "The activated Endpoint Extension (\(activated)) predates this MacFSW (\(bundledVersion)) and refuses the command-line tool. \(Self.setupHint)")
        }
        if bundledVersion != nil, activated == nil {
            return status(.notInstalled, running: nil, "The Endpoint Extension is not installed. \(Self.setupHint)")
        }
        return status(.unreachable, running: activated, "\(error.userFacingMessage) \(Self.setupHint)")
    }

    private func status(_ state: ExtensionStatus.State, running: MacFSWComponentVersion?, _ message: String) -> ExtensionStatus {
        ExtensionStatus(state: state, runningVersion: running?.description, bundledVersion: bundledVersion?.description, message: message)
    }
}
