import Foundation

public enum MacFSWRiskClassifier {
    private static let sensitivePathFragments = [
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/System/Library/LaunchAgents",
        "/System/Library/LaunchDaemons",
        "/Library/Preferences",
        "/private/var/db",
        "/private/etc",
        "/etc",
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/Applications",
        "Library/Application Support",
        "Library/Preferences",
        "Library/LaunchAgents",
        "TCC.db",
    ]

    public static func classify(_ event: MacFSWFileEvent) -> (MacFSWRiskLevel, [String]) {
        var reasons: [String] = []
        var risk: MacFSWRiskLevel = .low

        if [.unlink, .chmod, .chown, .setflags, .setacl, .deleteextattr].contains(event.eventType) {
            risk = max(risk, .medium)
            reasons.append("destructive or permission-changing operation")
        }

        if [.rename, .exchangedata].contains(event.eventType) {
            risk = max(risk, .medium)
            reasons.append("file replacement pattern")
        }

        if isSensitivePath(event.targetPath) || event.sourcePath.map(isSensitivePath) == true {
            risk = max(risk, .high)
            reasons.append("sensitive path")
        }

        if !event.process.isPlatformBinary,
           event.operationClass != .read,
           isPrivilegedPath(event.targetPath) {
            risk = max(risk, .high)
            reasons.append("third-party process modifying privileged path")
        }

        return (risk, reasons)
    }

    public static func isSensitivePath(_ path: String) -> Bool {
        sensitivePathFragments.contains { path.localizedCaseInsensitiveContains($0) }
    }

    private static func isPrivilegedPath(_ path: String) -> Bool {
        path.hasPrefix("/Library")
            || path.hasPrefix("/System")
            || path.hasPrefix("/private")
            || path.hasPrefix("/etc")
            || path.hasPrefix("/usr")
            || path.hasPrefix("/opt")
    }
}
