import Foundation

public enum MacFSWQueryValueKind: Equatable, Sendable {
    case eventType
    case operationClass
    case boolean
    case processName
    case pid
    case executable
    case signingID
    case teamID
    case path
    case numeric
    case text
}

public struct MacFSWQueryFieldDescriptor: Equatable, Sendable {
    public let field: MacFSWQueryField
    public let canonicalKey: String
    public let aliases: [String]
    public let valueKind: MacFSWQueryValueKind
    public let summary: String

    public init(
        field: MacFSWQueryField,
        canonicalKey: String,
        aliases: [String],
        valueKind: MacFSWQueryValueKind,
        summary: String
    ) {
        self.field = field
        self.canonicalKey = canonicalKey
        self.aliases = aliases
        self.valueKind = valueKind
        self.summary = summary
    }
}

/// Single source of truth for query field keys: the parser resolves raw keys
/// through this catalog, and suggestion UIs enumerate it, so the two can
/// never diverge. Aliases are stored pre-normalized (see `normalizedQueryKey`).
public enum MacFSWQueryFieldCatalog {
    /// One descriptor per `MacFSWQueryField` case, in suggestion display order.
    public static let descriptors: [MacFSWQueryFieldDescriptor] = [
        MacFSWQueryFieldDescriptor(
            field: .eventType,
            canonicalKey: "op",
            aliases: ["event", "events", "op", "operation", "type", "eventtype"],
            valueKind: .eventType,
            summary: "Event type (rename, unlink, write…)"
        ),
        MacFSWQueryFieldDescriptor(
            field: .path,
            canonicalKey: "path",
            aliases: ["path", "paths"],
            valueKind: .path,
            summary: "Target or source path"
        ),
        MacFSWQueryFieldDescriptor(
            field: .processName,
            canonicalKey: "process",
            aliases: ["name", "process", "proc", "processname", "process.name", "pname"],
            valueKind: .processName,
            summary: "Process name"
        ),
        MacFSWQueryFieldDescriptor(
            field: .pid,
            canonicalKey: "pid",
            aliases: ["pid", "processid", "process.id"],
            valueKind: .pid,
            summary: "Process identifier"
        ),
        MacFSWQueryFieldDescriptor(
            field: .executable,
            canonicalKey: "exe",
            aliases: ["exe", "exec", "executable", "executablepath", "process.executable"],
            valueKind: .executable,
            summary: "Executable path"
        ),
        MacFSWQueryFieldDescriptor(
            field: .signingID,
            canonicalKey: "signing",
            aliases: ["signing", "signingid", "signing.id", "process.signing", "process.signingid"],
            valueKind: .signingID,
            summary: "Code signing identifier"
        ),
        MacFSWQueryFieldDescriptor(
            field: .teamID,
            canonicalKey: "team",
            aliases: ["team", "teamid", "team.id", "process.team", "process.teamid"],
            valueKind: .teamID,
            summary: "Developer team identifier"
        ),
        MacFSWQueryFieldDescriptor(
            field: .operationClass,
            canonicalKey: "class",
            aliases: ["class", "operationclass", "opclass"],
            valueKind: .operationClass,
            summary: "Operation class (read, write, delete…)"
        ),
        MacFSWQueryFieldDescriptor(
            field: .platformBinary,
            canonicalKey: "platform",
            aliases: ["platform", "platformbinary", "platform.binary", "process.platform"],
            valueKind: .boolean,
            summary: "Platform binary (true/false)"
        ),
        MacFSWQueryFieldDescriptor(
            field: .appleControlled,
            canonicalKey: "apple",
            aliases: ["apple", "applecontrolled", "apple.controlled"],
            valueKind: .boolean,
            summary: "Apple-controlled process (true/false)"
        ),
        MacFSWQueryFieldDescriptor(
            field: .mutation,
            canonicalKey: "mutation",
            aliases: ["mutation", "mutating", "writeevent"],
            valueKind: .boolean,
            summary: "Mutating event (true/false)"
        ),
        MacFSWQueryFieldDescriptor(
            field: .targetPath,
            canonicalKey: "target",
            aliases: ["target", "targetpath", "path.target"],
            valueKind: .path,
            summary: "Target path"
        ),
        MacFSWQueryFieldDescriptor(
            field: .sourcePath,
            canonicalKey: "source",
            aliases: ["source", "src", "sourcepath", "path.source"],
            valueKind: .path,
            summary: "Source path (rename, clone…)"
        ),
        MacFSWQueryFieldDescriptor(
            field: .uid,
            canonicalKey: "uid",
            aliases: ["uid", "user", "userid", "user.id"],
            valueKind: .numeric,
            summary: "User identifier"
        ),
        MacFSWQueryFieldDescriptor(
            field: .gid,
            canonicalKey: "gid",
            aliases: ["gid", "group", "groupid", "group.id"],
            valueKind: .numeric,
            summary: "Group identifier"
        ),
        MacFSWQueryFieldDescriptor(
            field: .uidGid,
            canonicalKey: "uidgid",
            aliases: ["uidgid", "uid/gid", "usergroup", "user.group"],
            valueKind: .text,
            summary: "uid/gid pair"
        ),
        MacFSWQueryFieldDescriptor(
            field: .eventID,
            canonicalKey: "id",
            aliases: ["id", "uuid", "eventid", "event.id"],
            valueKind: .text,
            summary: "Event UUID"
        ),
        MacFSWQueryFieldDescriptor(
            field: .sequence,
            canonicalKey: "seq",
            aliases: ["seq", "sequence"],
            valueKind: .numeric,
            summary: "Event sequence number"
        ),
        MacFSWQueryFieldDescriptor(
            field: .timestamp,
            canonicalKey: "timestamp",
            aliases: ["timestamp", "ts", "time"],
            valueKind: .numeric,
            summary: "Event timestamp (ns)"
        ),
        MacFSWQueryFieldDescriptor(
            field: .rawType,
            canonicalKey: "rawtype",
            aliases: ["raw", "rawtype", "raw.type"],
            valueKind: .text,
            summary: "Raw ES event type"
        ),
        MacFSWQueryFieldDescriptor(
            field: .esVersion,
            canonicalKey: "esversion",
            aliases: ["version", "esversion", "es.version", "rawversion", "raw.version"],
            valueKind: .numeric,
            summary: "ES message version"
        ),
        MacFSWQueryFieldDescriptor(
            field: .flags,
            canonicalKey: "flags",
            aliases: ["flag", "flags"],
            valueKind: .numeric,
            summary: "Event flags"
        ),
        MacFSWQueryFieldDescriptor(
            field: .parameters,
            canonicalKey: "detail",
            aliases: ["param", "params", "parameter", "parameters", "detail", "details", "metadata"],
            valueKind: .text,
            summary: "Operation parameters and details"
        ),
        MacFSWQueryFieldDescriptor(
            field: .auditToken,
            canonicalKey: "audit",
            aliases: ["audit", "audittoken", "audit.token"],
            valueKind: .text,
            summary: "Audit token"
        ),
        MacFSWQueryFieldDescriptor(
            field: .cdhash,
            canonicalKey: "cdhash",
            aliases: ["cdhash", "codehash"],
            valueKind: .text,
            summary: "Code directory hash"
        ),
        MacFSWQueryFieldDescriptor(
            field: .any,
            canonicalKey: "any",
            aliases: ["any", "text", "q", "query"],
            valueKind: .text,
            summary: "Full-text match"
        ),
    ]

    public static func field(forRawKey rawKey: String) -> MacFSWQueryField? {
        lookupIndex[normalizeKey(rawKey)]
    }

    /// The parser's key normalization, exposed so completion UIs can match
    /// partial input the same way the parser matches full keys.
    public static func normalizeKey(_ rawKey: String) -> String {
        rawKey.normalizedQueryKey
    }

    public static func descriptor(for field: MacFSWQueryField) -> MacFSWQueryFieldDescriptor? {
        descriptorIndex[field]
    }

    private static let lookupIndex: [String: MacFSWQueryField] = {
        var index: [String: MacFSWQueryField] = [:]
        for descriptor in descriptors {
            for alias in descriptor.aliases {
                index[alias] = descriptor.field
            }
        }
        return index
    }()

    private static let descriptorIndex: [MacFSWQueryField: MacFSWQueryFieldDescriptor] =
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.field, $0) })
}
