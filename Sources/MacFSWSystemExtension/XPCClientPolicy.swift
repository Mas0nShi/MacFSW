import Foundation

/// Which signed clients may open capture streams: the MacFSW app, which
/// also installs the extension, and the `macfsw` command-line tool shipped
/// inside it. Both must be signed by the same team.
public struct XPCClientPolicy: Sendable {
    public var teamIdentifier: String
    public var hostIdentifier: String
    public var cliIdentifier: String

    public init(
        teamIdentifier: String = "UYF535Y9QZ",
        hostIdentifier: String = "com.mas0n.MacFSW",
        cliIdentifier: String = "com.mas0n.MacFSW.cli"
    ) {
        self.teamIdentifier = teamIdentifier
        self.hostIdentifier = hostIdentifier
        self.cliIdentifier = cliIdentifier
    }

    /// A code-signing requirement the system checks against each peer's
    /// audit token, so the identity cannot be swapped out by PID reuse.
    public var requirement: String {
        let team = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        let host = "identifier \"\(hostIdentifier)\" and \(team) and entitlement[\"com.apple.developer.system-extension.install\"] exists"
        let cli = "identifier \"\(cliIdentifier)\" and \(team)"
        return "(\(host)) or (\(cli))"
    }
}
