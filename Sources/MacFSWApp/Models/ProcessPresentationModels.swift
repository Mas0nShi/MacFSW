import Foundation
import MacFSWCore

enum MacFSWProcessLifecycle: String, Equatable, Sendable {
    case running
    case exited
    case unknown

    var title: String {
        switch self {
        case .running: "Running"
        case .exited: "Exited"
        case .unknown: "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "circle.fill"
        case .exited: "circle"
        case .unknown: "questionmark.circle"
        }
    }
}

struct MacFSWProcessSummary: Identifiable, Equatable, Sendable {
    var id: String
    var processName: String
    var pid: Int32
    var auditToken: String
    var executablePath: String
    var signingSummary: String
    var uid: UInt32
    var gid: UInt32
    var eventCount: Int
    var lastEventNS: UInt64
    var isPlatformBinary: Bool
    var identityCount: Int
    var lifecycle: MacFSWProcessLifecycle

    var displayName: String {
        "\(processName)(\(pid))"
    }

    var filterIdentity: MacFSWProcessFilterIdentity {
        MacFSWProcessFilterIdentity(pid: pid, auditToken: auditToken, executablePath: executablePath)
    }

    var isAppleSigned: Bool {
        signingSummary.lowercased().hasPrefix("com.apple.")
    }

    var processIconSymbolName: String {
        if isAppleSigned {
            return "apple.logo"
        }
        if isAppBundleExecutable {
            return "macwindow"
        }
        if isDaemonLike {
            return "gearshape"
        }
        if isCommandLineExecutable {
            return "terminal"
        }
        return "macwindow"
    }

    var appBundlePath: String? {
        Self.appBundlePath(for: executablePath)
    }

    private var isAppBundleExecutable: Bool {
        appBundlePath != nil
    }

    private var isDaemonLike: Bool {
        processName.lowercased().hasSuffix("d")
    }

    private var isCommandLineExecutable: Bool {
        let path = executablePath.lowercased()
        return path.hasPrefix("/bin/")
            || path.hasPrefix("/sbin/")
            || path.hasPrefix("/usr/bin/")
            || path.hasPrefix("/usr/sbin/")
            || path.hasPrefix("/usr/local/bin/")
            || path.hasPrefix("/opt/homebrew/")
    }

    static func appBundlePath(for executablePath: String) -> String? {
        let components = (executablePath as NSString).pathComponents
        guard let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        return NSString.path(withComponents: Array(components.prefix(appIndex + 1)))
    }

    init(
        id: String,
        processName: String,
        pid: Int32,
        auditToken: String,
        executablePath: String,
        signingSummary: String,
        uid: UInt32,
        gid: UInt32,
        eventCount: Int,
        lastEventNS: UInt64,
        isPlatformBinary: Bool,
        identityCount: Int = 1,
        lifecycle: MacFSWProcessLifecycle = .unknown
    ) {
        self.id = id
        self.processName = processName
        self.pid = pid
        self.auditToken = auditToken
        self.executablePath = executablePath
        self.signingSummary = signingSummary
        self.uid = uid
        self.gid = gid
        self.eventCount = eventCount
        self.lastEventNS = lastEventNS
        self.isPlatformBinary = isPlatformBinary
        self.identityCount = identityCount
        self.lifecycle = lifecycle
    }

    init(coreSummary: MacFSWProcessEventSummary) {
        self.init(
            id: coreSummary.id,
            processName: coreSummary.processName,
            pid: coreSummary.pid,
            auditToken: coreSummary.auditToken,
            executablePath: coreSummary.executablePath,
            signingSummary: coreSummary.signingSummary,
            uid: coreSummary.uid,
            gid: coreSummary.gid,
            eventCount: coreSummary.eventCount,
            lastEventNS: coreSummary.lastEventNS,
            isPlatformBinary: coreSummary.isPlatformBinary,
            identityCount: coreSummary.identityCount
        )
    }
}

struct MacFSWProcessGroupSummary: Identifiable, Equatable, Sendable {
    var id: String { processName }
    var processName: String
    var summaries: [MacFSWProcessSummary]
    var eventCount: Int
    var lastEventNS: UInt64
    var exitedCount: Int

    var instanceCount: Int {
        summaries.count
    }

    var processIconSymbolName: String {
        representativeSummary?.processIconSymbolName ?? "macwindow"
    }

    var representativeSummary: MacFSWProcessSummary? {
        summaries.max { left, right in
            if left.eventCount == right.eventCount {
                return left.lastEventNS < right.lastEventNS
            }
            return left.eventCount < right.eventCount
        }
    }
}
