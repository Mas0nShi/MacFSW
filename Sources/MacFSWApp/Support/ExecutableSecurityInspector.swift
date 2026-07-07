import Foundation
import Security

/// Sandbox posture of an executable as signed on disk.
enum ExecutableSandboxStatus: Equatable, Sendable {
    case sandboxed
    case notSandboxed
    case unknown
}

struct EntitlementEntry: Identifiable, Equatable, Sendable {
    var key: String
    var value: String
    /// Individual elements when the plist value is an array; empty for scalars.
    /// Kept in the binary's declared order.
    var items: [String] = []

    var id: String { key }
}

/// A BSD file flag (`st_flags`) worth surfacing: SIP protection, immutability,
/// append-only, and similar security-relevant bits. Noise flags such as
/// `compressed` are deliberately excluded.
struct FileFlag: Equatable, Sendable, Identifiable {
    var name: String
    var isSystemEnforced: Bool

    var id: String { name }
}

/// POSIX permission bits of a filesystem node, resolved to display-ready forms.
struct FilePermissionSnapshot: Equatable, Sendable {
    var mode: mode_t
    var owner: String
    var group: String
    var flags: UInt32 = 0

    var isSetUserID: Bool { mode & S_ISUID != 0 }
    var isSetGroupID: Bool { mode & S_ISGID != 0 }
    var isSticky: Bool { mode & S_ISVTX != 0 }

    var fileFlags: [FileFlag] {
        let systemEnforced: [(bit: UInt32, name: String)] = [
            (UInt32(SF_RESTRICTED), "restricted"),
            (UInt32(SF_NOUNLINK), "sunlnk"),
            (UInt32(SF_IMMUTABLE), "schg"),
            (UInt32(SF_APPEND), "sappnd"),
        ]
        let userScoped: [(bit: UInt32, name: String)] = [
            (UInt32(UF_IMMUTABLE), "uchg"),
            (UInt32(UF_APPEND), "uappnd"),
            (UInt32(UF_DATAVAULT), "datavault"),
            (UInt32(UF_HIDDEN), "hidden"),
        ]
        return systemEnforced.filter { flags & $0.bit != 0 }.map { FileFlag(name: $0.name, isSystemEnforced: true) }
            + userScoped.filter { flags & $0.bit != 0 }.map { FileFlag(name: $0.name, isSystemEnforced: false) }
    }

    var octal: String {
        String(format: "%04o", Int(mode & 0o7777))
    }

    var symbolic: String {
        func triad(read: mode_t, write: mode_t, execute: mode_t, special: mode_t, executableMark: Character, specialOnlyMark: Character) -> String {
            var part = ""
            part.append(mode & read != 0 ? "r" : "-")
            part.append(mode & write != 0 ? "w" : "-")
            let isExecutable = mode & execute != 0
            if mode & special != 0 {
                part.append(isExecutable ? executableMark : specialOnlyMark)
            } else {
                part.append(isExecutable ? "x" : "-")
            }
            return part
        }

        return String(fileTypeCharacter)
            + triad(read: S_IRUSR, write: S_IWUSR, execute: S_IXUSR, special: S_ISUID, executableMark: "s", specialOnlyMark: "S")
            + triad(read: S_IRGRP, write: S_IWGRP, execute: S_IXGRP, special: S_ISGID, executableMark: "s", specialOnlyMark: "S")
            + triad(read: S_IROTH, write: S_IWOTH, execute: S_IXOTH, special: S_ISVTX, executableMark: "t", specialOnlyMark: "T")
    }

    var displayText: String {
        let base = "\(symbolic) \(octal) \(owner):\(group)"
        let flagNames = fileFlags.map(\.name)
        return flagNames.isEmpty ? base : "\(base) \(flagNames.joined(separator: ","))"
    }

    private var fileTypeCharacter: Character {
        switch mode & S_IFMT {
        case S_IFDIR: "d"
        case S_IFLNK: "l"
        case S_IFSOCK: "s"
        case S_IFIFO: "p"
        case S_IFCHR: "c"
        case S_IFBLK: "b"
        default: "-"
        }
    }
}

/// Security posture of the executable currently on disk. This is read at display
/// time, so it can differ from the binary that actually emitted a stored event.
struct ExecutableSecuritySnapshot: Equatable, Sendable {
    var sandbox: ExecutableSandboxStatus
    var hasHardenedRuntime: Bool
    var entitlements: [EntitlementEntry]
    var permissions: FilePermissionSnapshot
}

struct EventSecurityReport: Equatable, Sendable {
    var executable: ExecutableSecuritySnapshot?
    var targetPermissions: FilePermissionSnapshot?
    var sourcePermissions: FilePermissionSnapshot?
}

/// Reads code-signing information (entitlements, hardened runtime) and permission
/// bits for executables referenced by events. Signing lookups are cached per path
/// and invalidated when the file's modification time or size changes.
actor ExecutableSecurityInspector {
    static let shared = ExecutableSecurityInspector()

    private struct CacheEntry {
        var modificationTimeNS: Int64
        var size: off_t
        var snapshot: ExecutableSecuritySnapshot
    }

    private var cache: [String: CacheEntry] = [:]
    private let cacheLimit = 256

    func report(executablePath: String, targetPath: String?, sourcePath: String? = nil) -> EventSecurityReport {
        EventSecurityReport(
            executable: snapshot(forExecutableAt: executablePath),
            targetPermissions: targetPath.flatMap { permissionSnapshot(atPath: $0, followSymlinks: false) },
            sourcePermissions: sourcePath.flatMap { permissionSnapshot(atPath: $0, followSymlinks: false) }
        )
    }

    static func sandboxStatus(entitlements: [String: Any]?, signingReadFailed: Bool) -> ExecutableSandboxStatus {
        guard let entitlements else {
            return signingReadFailed ? .unknown : .notSandboxed
        }
        return (entitlements["com.apple.security.app-sandbox"] as? Bool) == true ? .sandboxed : .notSandboxed
    }

    static func entitlementEntry(key: String, value: Any) -> EntitlementEntry {
        if let array = value as? [Any] {
            let rendered = array.map(renderedEntitlementValue)
            return EntitlementEntry(key: key, value: rendered.joined(separator: ", "), items: rendered)
        }
        return EntitlementEntry(key: key, value: renderedEntitlementValue(value))
    }

    static func renderedEntitlementValue(_ value: Any) -> String {
        if let array = value as? [Any] {
            return array.map(renderedEntitlementValue).joined(separator: ", ")
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted()
                .map { "\($0): \(renderedEntitlementValue(dictionary[$0]!))" }
                .joined(separator: ", ")
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        if let data = value as? Data {
            return "\(data.count)-byte data"
        }
        return String(describing: value)
    }

    private func snapshot(forExecutableAt path: String) -> ExecutableSecuritySnapshot? {
        guard !path.isEmpty else {
            return nil
        }

        var status = stat()
        guard stat(path, &status) == 0 else {
            cache[path] = nil
            return nil
        }

        let modificationTimeNS = Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec)
        if let entry = cache[path], entry.modificationTimeNS == modificationTimeNS, entry.size == status.st_size {
            return entry.snapshot
        }

        let signing = signingInspection(atPath: path)
        let entitlements = (signing.entitlements ?? [:])
            .map { Self.entitlementEntry(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }

        let snapshot = ExecutableSecuritySnapshot(
            sandbox: Self.sandboxStatus(entitlements: signing.entitlements, signingReadFailed: signing.readFailed),
            hasHardenedRuntime: signing.hasHardenedRuntime,
            entitlements: entitlements,
            permissions: FilePermissionSnapshot(
                mode: status.st_mode,
                owner: userName(for: status.st_uid),
                group: groupName(for: status.st_gid),
                flags: status.st_flags
            )
        )

        if cache.count >= cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        cache[path] = CacheEntry(modificationTimeNS: modificationTimeNS, size: status.st_size, snapshot: snapshot)
        return snapshot
    }

    private struct SigningInspection {
        var entitlements: [String: Any]?
        var hasHardenedRuntime: Bool
        var readFailed: Bool
    }

    private func signingInspection(atPath path: String) -> SigningInspection {
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess, let staticCode else {
            return SigningInspection(entitlements: nil, hasHardenedRuntime: false, readFailed: true)
        }

        var rawInfo: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        let copyStatus = SecCodeCopySigningInformation(staticCode, flags, &rawInfo)
        if copyStatus == errSecCSUnsigned {
            return SigningInspection(entitlements: nil, hasHardenedRuntime: false, readFailed: false)
        }
        guard copyStatus == errSecSuccess, let info = rawInfo as? [String: Any] else {
            return SigningInspection(entitlements: nil, hasHardenedRuntime: false, readFailed: true)
        }

        // Unsigned binaries report success but omit the signing identifier.
        guard info[kSecCodeInfoIdentifier as String] != nil else {
            return SigningInspection(entitlements: nil, hasHardenedRuntime: false, readFailed: false)
        }

        let codeSignatureFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return SigningInspection(
            entitlements: entitlementsDictionary(from: info) ?? [:],
            hasHardenedRuntime: codeSignatureFlags & SecCodeSignatureFlags.runtime.rawValue != 0,
            readFailed: false
        )
    }

    private func entitlementsDictionary(from info: [String: Any]) -> [String: Any]? {
        if let dictionary = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            return dictionary
        }

        // Older signatures only expose the raw entitlements blob: a magic + length
        // header (8 bytes) followed by a property list.
        guard let blob = info[kSecCodeInfoEntitlements as String] as? Data else {
            return nil
        }
        let payload = blob.count > 8 && blob.starts(with: [0xFA, 0xDE, 0x71, 0x71]) ? blob.dropFirst(8) : blob
        let plist = try? PropertyListSerialization.propertyList(from: Data(payload), options: [], format: nil)
        return plist as? [String: Any]
    }

    private func permissionSnapshot(atPath path: String, followSymlinks: Bool) -> FilePermissionSnapshot? {
        guard !path.isEmpty else {
            return nil
        }
        var status = stat()
        let result = followSymlinks ? stat(path, &status) : lstat(path, &status)
        guard result == 0 else {
            return nil
        }
        return FilePermissionSnapshot(
            mode: status.st_mode,
            owner: userName(for: status.st_uid),
            group: groupName(for: status.st_gid),
            flags: status.st_flags
        )
    }

    private func userName(for uid: uid_t) -> String {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 1024)
        if getpwuid_r(uid, &record, &buffer, buffer.count, &result) == 0, result != nil {
            return String(cString: record.pw_name)
        }
        return String(uid)
    }

    private func groupName(for gid: gid_t) -> String {
        var record = group()
        var result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 1024)
        if getgrgid_r(gid, &record, &buffer, buffer.count, &result) == 0, result != nil {
            return String(cString: record.gr_name)
        }
        return String(gid)
    }
}
