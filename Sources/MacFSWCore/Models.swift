import Foundation

public enum MacFSWEventType: String, Codable, CaseIterable, Identifiable, Sendable {
    case create
    case open
    case close
    case write
    case rename
    case unlink
    case link
    case clone
    case copyfile
    case truncate
    case exchangedata
    case chmod
    case chown
    case setflags
    case setacl
    case setextattr
    case deleteextattr
    case utimes
    case unknown

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = MacFSWEventType(rawValue: rawValue) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var operationClass: MacFSWOperationClass {
        switch self {
        case .open, .close:
            .read
        case .create, .write, .clone, .copyfile, .truncate:
            .write
        case .rename, .link, .exchangedata:
            .link
        case .unlink:
            .delete
        case .chmod, .chown, .setflags, .setacl, .setextattr, .deleteextattr, .utimes:
            .metadata
        case .unknown:
            .unknown
        }
    }

    public var isMutation: Bool {
        operationClass != .read && operationClass != .unknown
    }

    public static var defaultCaptureTypes: [MacFSWEventType] {
        allCases.filter { $0.isDefaultCaptureType }
    }

    public static var verboseCaptureTypes: [MacFSWEventType] {
        allCases.filter { $0.isTransportSafeCaptureType }
    }

    public var isTransportSafeCaptureType: Bool {
        switch self {
        case .unknown, .setflags:
            false
        default:
            true
        }
    }

    private var isDefaultCaptureType: Bool {
        isMutation && isTransportSafeCaptureType
    }
}

public enum MacFSWOperationClass: String, Codable, CaseIterable, Identifiable, Sendable {
    case read
    case write
    case metadata
    case delete
    case link
    case unknown

    public var id: String { rawValue }
}

public struct MacFSWProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var auditToken: String
    public var executablePath: String
    public var processName: String
    public var signingID: String?
    public var teamID: String?
    public var cdhash: String?
    public var isPlatformBinary: Bool

    public init(
        pid: Int32,
        auditToken: String,
        executablePath: String,
        processName: String,
        signingID: String? = nil,
        teamID: String? = nil,
        cdhash: String? = nil,
        isPlatformBinary: Bool = false
    ) {
        self.pid = pid
        self.auditToken = auditToken
        self.executablePath = executablePath
        self.processName = processName
        self.signingID = signingID
        self.teamID = teamID
        self.cdhash = cdhash
        self.isPlatformBinary = isPlatformBinary
    }
}

public struct MacFSWProcessFilterIdentity: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var auditToken: String
    public var executablePath: String

    public init(pid: Int32, auditToken: String, executablePath: String) {
        self.pid = pid
        self.auditToken = auditToken
        self.executablePath = executablePath
    }

    public init(process: MacFSWProcessIdentity) {
        self.init(
            pid: process.pid,
            auditToken: process.auditToken,
            executablePath: process.executablePath
        )
    }

    public var usesAuditToken: Bool {
        !auditToken.isEmpty
    }

    public var stableID: String {
        "pid:\(pid)"
    }

    public func matches(_ process: MacFSWProcessIdentity) -> Bool {
        process.pid == pid
    }
}

public extension MacFSWProcessIdentity {
    var filterIdentity: MacFSWProcessFilterIdentity {
        MacFSWProcessFilterIdentity(process: self)
    }
}

public struct MacFSWEventParameter: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var value: String

    public init(key: String, label: String, value: String) {
        self.key = key
        self.label = label
        self.value = value
    }

    public var id: String {
        key
    }

    public var displayText: String {
        "\(label): \(value)"
    }
}

public struct MacFSWFileEvent: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var sequence: UInt64
    public var timestampNS: UInt64
    public var eventType: MacFSWEventType
    public var operationClass: MacFSWOperationClass
    public var process: MacFSWProcessIdentity
    public var targetPath: String
    public var sourcePath: String?
    public var parameters: [MacFSWEventParameter]
    public var fileID: UInt64?
    public var flags: UInt64
    public var uid: UInt32
    public var gid: UInt32
    public var rawEventType: String
    public var rawEventTypeValue: UInt32?
    public var rawEventVersion: UInt32

    public init(
        id: UUID = UUID(),
        sequence: UInt64 = 0,
        timestampNS: UInt64 = MacFSWClock.nowNanoseconds(),
        eventType: MacFSWEventType,
        operationClass: MacFSWOperationClass? = nil,
        process: MacFSWProcessIdentity,
        targetPath: String,
        sourcePath: String? = nil,
        parameters: [MacFSWEventParameter] = [],
        fileID: UInt64? = nil,
        flags: UInt64 = 0,
        uid: UInt32 = 0,
        gid: UInt32 = 0,
        rawEventType: String? = nil,
        rawEventTypeValue: UInt32? = nil,
        rawEventVersion: UInt32 = 1
    ) {
        self.id = id
        self.sequence = sequence
        self.timestampNS = timestampNS
        self.eventType = eventType
        self.operationClass = operationClass ?? eventType.operationClass
        self.process = process
        self.targetPath = targetPath
        self.sourcePath = sourcePath
        self.parameters = parameters
        self.fileID = fileID
        self.flags = flags
        self.uid = uid
        self.gid = gid
        self.rawEventType = rawEventType ?? eventType.rawValue
        self.rawEventTypeValue = rawEventTypeValue
        self.rawEventVersion = rawEventVersion
    }

    public var parameterText: String {
        parameters
            .flatMap { [$0.key, $0.label, $0.value] }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var operationDetailSummary: String {
        Self.operationDetailSummary(
            eventType: eventType,
            sourcePath: sourcePath,
            parameters: parameters
        )
    }

    public static func operationDetailSummary(
        eventType: MacFSWEventType,
        sourcePath: String?,
        parameters: [MacFSWEventParameter]
    ) -> String {
        func value(_ key: String) -> String? {
            parameters.first { $0.key == key }?.value
        }

        func joined(_ parts: [String?]) -> String {
            parts.compactMap { part in
                guard let part, !part.isEmpty else {
                    return nil
                }
                return part
            }
            .joined(separator: " · ")
        }

        switch eventType {
        case .rename:
            return sourcePath.map { "from \($0)" } ?? ""
        case .clone, .copyfile, .link, .exchangedata:
            return joined([
                sourcePath.map { "from \($0)" },
                value("copy_flags").map { "flags \($0)" },
            ])
        case .chmod:
            return joined([
                value("mode").map { "mode \($0)" },
                value("current_mode").map { "was \($0)" },
            ])
        case .chown:
            let currentOwner = [value("current_uid"), value("current_gid")]
                .compactMap { $0 }
                .joined(separator: "/")
            return joined([
                joined([value("uid").map { "uid \($0)" }, value("gid").map { "gid \($0)" }]),
                currentOwner.isEmpty ? nil : "was \(currentOwner)",
            ])
        case .setflags:
            return joined([
                value("flags").map { "flags \($0)" },
                value("current_flags").map { "was \($0)" },
            ])
        case .setacl:
            return value("acl_action").map { "ACL \($0)" } ?? ""
        case .setextattr, .deleteextattr:
            return value("xattr").map { "xattr \($0)" } ?? ""
        case .utimes:
            return joined([
                value("mtime").map { "mtime \($0)" },
                value("atime").map { "atime \($0)" },
            ])
        default:
            if !parameters.isEmpty {
                return parameters.map(\.displayText).joined(separator: " · ")
            }
            return sourcePath.map { "Source: \($0)" } ?? ""
        }
    }
}

public struct MacFSWAnnotation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var eventID: UUID
    public var tag: String
    public var note: String
    public var createdAt: Date

    public init(id: UUID = UUID(), eventID: UUID, tag: String, note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.eventID = eventID
        self.tag = tag
        self.note = note
        self.createdAt = createdAt
    }
}

public enum MacFSWClock {
    public static func nowNanoseconds() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }
}
