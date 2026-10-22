import Darwin
import Foundation

extension MacFSWFileEvent {
    /// What the event changed, in words a reader can take in at a glance:
    /// `rwxr-xr-x → rw-r--r-- (0644)`, `root:wheel → mason:staff`,
    /// `+hidden −uchg`. Empty when the operation itself says it all (write,
    /// create, delete, …). Source paths are left to the path column, which
    /// shows them as `old → new`.
    public static func operationDetailSummary(
        eventType: MacFSWEventType,
        sourcePath: String?,
        parameters: [MacFSWEventParameter]
    ) -> String {
        func value(_ key: String) -> String? {
            parameters.first { $0.key == key }?.value.nonEmptyValue
        }

        switch eventType {
        case .rename:
            return value("destination_type") == "existing" ? "replaced an existing file" : ""
        case .clone, .copyfile, .link, .exchangedata:
            return ""
        case .chmod:
            guard let mode = value("mode").flatMap({ mode_t($0, radix: 8) }) else {
                return ""
            }
            let new = "\(symbolicMode(mode)) (\(String(format: "%04o", Int(mode))))"
            guard let current = value("current_mode").flatMap({ mode_t($0, radix: 8) }), current != mode else {
                return new
            }
            return "\(symbolicMode(current)) → \(new)"
        case .chown:
            let currentOwner = value("current_uid").map(userName)
            let currentGroup = value("current_gid").map(groupName)
            let owner = value("uid").flatMap { $0 == "unchanged" ? currentOwner : userName($0) }
            let group = value("gid").flatMap { $0 == "unchanged" ? currentGroup : groupName($0) }
            let new = "\(owner ?? "?"):\(group ?? "?")"
            guard let currentOwner, let currentGroup else {
                return new
            }
            let current = "\(currentOwner):\(currentGroup)"
            return current == new ? new : "\(current) → \(new)"
        case .setflags:
            guard let flags = value("flags").flatMap(hexValue) else {
                return ""
            }
            let current = value("current_flags").flatMap(hexValue) ?? 0
            let added = fileFlagNames(flags & ~current).map { "+\($0)" }
            let removed = fileFlagNames(current & ~flags).map { "−\($0)" }
            let changes = added + removed
            return changes.isEmpty ? "flags unchanged" : changes.joined(separator: " ")
        case .setacl:
            return value("acl_action") == "clear" ? "ACL cleared" : "ACL set"
        case .setextattr, .deleteextattr:
            return value("xattr") ?? ""
        case .utimes:
            return value("mtime").flatMap(timestampText).map { "modified time → \($0)" } ?? ""
        default:
            return parameters.map(\.displayText).joined(separator: " · ")
        }
    }

    /// `ls -l` style permission triads, with setuid/setgid/sticky marks.
    static func symbolicMode(_ mode: mode_t) -> String {
        func triad(_ shift: mode_t, special: mode_t, mark: Character) -> String {
            let bits = (mode >> shift) & 0o7
            var text = ""
            text.append(bits & 0o4 != 0 ? "r" : "-")
            text.append(bits & 0o2 != 0 ? "w" : "-")
            let executable = bits & 0o1 != 0
            if mode & special != 0 {
                text.append(executable ? mark : Character(mark.uppercased()))
            } else {
                text.append(executable ? "x" : "-")
            }
            return text
        }
        return triad(6, special: S_ISUID, mark: "s") + triad(3, special: S_ISGID, mark: "s") + triad(0, special: S_ISVTX, mark: "t")
    }

    /// `chflags` names for the BSD file flags people set on purpose.
    static func fileFlagNames(_ flags: UInt32) -> [String] {
        let names: [(UInt32, String)] = [
            (UInt32(UF_NODUMP), "nodump"),
            (UInt32(UF_IMMUTABLE), "uchg"),
            (UInt32(UF_APPEND), "uappnd"),
            (UInt32(UF_OPAQUE), "opaque"),
            (UInt32(UF_HIDDEN), "hidden"),
            (UInt32(SF_ARCHIVED), "arch"),
            (UInt32(SF_IMMUTABLE), "schg"),
            (UInt32(SF_APPEND), "sappnd"),
            (UInt32(SF_RESTRICTED), "restricted"),
            (UInt32(SF_NOUNLINK), "sunlnk"),
        ]
        return names.filter { flags & $0.0 != 0 }.map(\.1)
    }

    private static func hexValue(_ text: String) -> UInt32? {
        UInt32(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: 16)
    }

    private static func timestampText(_ text: String) -> String? {
        guard let seconds = Double(text) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
            .formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
    }

    private static func userName(_ id: String) -> String {
        guard let uid = uid_t(id) else {
            return id
        }
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        guard getpwuid_r(uid, &entry, &buffer, buffer.count, &result) == 0, let name = result?.pointee.pw_name else {
            return id
        }
        return String(cString: name)
    }

    private static func groupName(_ id: String) -> String {
        guard let gid = gid_t(id) else {
            return id
        }
        var entry = group()
        var result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 1024)
        guard getgrgid_r(gid, &entry, &buffer, buffer.count, &result) == 0, let name = result?.pointee.gr_name else {
            return id
        }
        return String(cString: name)
    }
}

private extension String {
    var nonEmptyValue: String? {
        isEmpty ? nil : self
    }
}
