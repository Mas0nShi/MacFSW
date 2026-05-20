import Foundation
import MacFSWCore

#if canImport(EndpointSecurity)
import Darwin
import EndpointSecurity
#endif

public enum EndpointSecurityCaptureError: Error, LocalizedError, Sendable {
    case unsupportedPlatform
    case clientCreationFailed(EndpointSecurityClientCreationFailure)
    case subscriptionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Endpoint Security is not available on this platform."
        case .clientCreationFailed(let failure):
            failure.message
        case .subscriptionFailed(let message):
            "Endpoint Security subscription failed: \(message)"
        }
    }
}

public struct EndpointSecurityClientCreationFailure: Equatable, Sendable {
    public var code: Int
    public var name: String
    public var fullDiskAccessRequired: Bool

    public var message: String {
        if fullDiskAccessRequired {
            return "MacFSW Endpoint Extension needs Full Disk Access / Endpoint Security permission. Open System Settings > Privacy & Security > Full Disk Access, enable MacFSW Endpoint Extension, then try recording again. This permission is for the System Extension, not the host app. (\(name), rawValue: \(code))"
        }
        return "Endpoint Security client creation failed: \(name) (rawValue: \(code))"
    }
}

public final class EndpointSecurityCapture: @unchecked Sendable {
    public static var isAvailable: Bool {
        #if canImport(EndpointSecurity)
        true
        #else
        false
        #endif
    }

    private let config: MacFSWCaptureConfig
    private let onBatch: @Sendable (MacFSWEventBatch) -> Void
    private let onFinish: @Sendable (String?) -> Void
    private let lock = NSLock()
    private var pending: [MacFSWFileEvent] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.mas0n.MacFSW.EndpointCapture", qos: .userInitiated)
    private var stats = MacFSWCaptureStats()
    private var state: MacFSWCaptureState = .idle

    #if canImport(EndpointSecurity)
    private var client: OpaquePointer?
    #endif

    public init(
        config: MacFSWCaptureConfig,
        onBatch: @escaping @Sendable (MacFSWEventBatch) -> Void,
        onFinish: @escaping @Sendable (String?) -> Void
    ) {
        self.config = config
        self.onBatch = onBatch
        self.onFinish = onFinish
    }

    deinit {
        stop()
    }

    public func start() throws {
        #if canImport(EndpointSecurity)
        lock.lock()
        guard state != .recording else {
            lock.unlock()
            return
        }
        state = .recording
        stats.startedAt = Date()
        stats.activeSubscriptions = config.eventTypes
        lock.unlock()

        var newClient: OpaquePointer?
        let createResult = es_new_client(&newClient) { [weak self] _, message in
            self?.handle(message: message)
        }

        guard createResult == ES_NEW_CLIENT_RESULT_SUCCESS, let newClient else {
            lock.lock()
            state = .failed
            lock.unlock()
            throw EndpointSecurityCaptureError.clientCreationFailed(Self.clientCreationFailure(from: createResult))
        }

        client = newClient
        try subscribe(client: newClient)
        applyMuteConfiguration(client: newClient)
        startTimer()
        #else
        throw EndpointSecurityCaptureError.unsupportedPlatform
        #endif
    }

    public static func authorizationHealth() -> MacFSWCaptureHealth {
        #if canImport(EndpointSecurity)
        var newClient: OpaquePointer?
        let createResult = es_new_client(&newClient) { _, _ in }
        guard createResult == ES_NEW_CLIENT_RESULT_SUCCESS, let newClient else {
            let failure = clientCreationFailure(from: createResult)
            return MacFSWCaptureHealth(
                state: .degraded,
                endpointSecurityAvailable: true,
                endpointSecurityAuthorized: false,
                fullDiskAccessHint: failure.fullDiskAccessRequired,
                message: failure.message
            )
        }
        es_delete_client(newClient)
        return MacFSWCaptureHealth(
            state: .idle,
            endpointSecurityAvailable: true,
            endpointSecurityAuthorized: true,
            message: "MacFSW Endpoint Extension has Endpoint Security permission."
        )
        #else
        return MacFSWCaptureHealth(
            state: .degraded,
            endpointSecurityAvailable: false,
            endpointSecurityAuthorized: false,
            message: "Endpoint Security is not available on this platform."
        )
        #endif
    }

    public func stop() {
        #if canImport(EndpointSecurity)
        lock.lock()
        state = .stopping
        let existingTimer = timer
        timer = nil
        let existingClient = client
        client = nil
        lock.unlock()

        existingTimer?.cancel()
        flush()

        if let existingClient {
            es_unsubscribe_all(existingClient)
            es_delete_client(existingClient)
        }
        #endif

        lock.lock()
        if state == .stopping {
            state = .stopped
        }
        lock.unlock()
    }

    public func health() -> MacFSWCaptureHealth {
        lock.lock()
        let snapshotStats = stats
        let snapshotState = state
        lock.unlock()

        return MacFSWCaptureHealth(
            state: snapshotState,
            endpointSecurityAvailable: Self.isAvailable,
            endpointSecurityAuthorized: snapshotState == .recording,
            stats: snapshotStats,
            message: snapshotState == .recording ? "Endpoint Security capture stream is active." : "Capture is idle."
        )
    }

    #if canImport(EndpointSecurity)
    private func subscribe(client: OpaquePointer) throws {
        var events = config.eventTypes.compactMap(esEventType)
        if events.isEmpty {
            events = MacFSWEventType.defaultCaptureTypes.compactMap(esEventType)
        }
        let result = events.withUnsafeBufferPointer { buffer in
            es_subscribe(client, buffer.baseAddress!, UInt32(buffer.count))
        }
        guard result == ES_RETURN_SUCCESS else {
            throw EndpointSecurityCaptureError.subscriptionFailed(String(describing: result))
        }
    }

    private func applyMuteConfiguration(client: OpaquePointer) {
        for path in config.excludePaths where !path.isEmpty {
            es_mute_path(client, path, ES_MUTE_PATH_TYPE_TARGET_PREFIX)
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(config.batchIntervalMS), repeating: .milliseconds(config.batchIntervalMS))
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func handle(message: UnsafePointer<es_message_t>) {
        guard let event = snapshot(message: message) else {
            return
        }

        lock.lock()
        stats.receivedEvents += 1
        stats.lastEventAt = Date()
        if pending.count >= max(config.batchSize * 4, 1024) {
            stats.droppedEvents += 1
            lock.unlock()
            return
        }
        pending.append(event)
        let shouldFlush = pending.count >= config.batchSize
        lock.unlock()

        if shouldFlush {
            queue.async { [weak self] in
                self?.flush()
            }
        }
    }

    private func flush() {
        lock.lock()
        let batchEvents = pending
        pending.removeAll(keepingCapacity: true)
        stats.queuedEvents = pending.count
        stats.deliveredEvents += UInt64(batchEvents.count)
        let batchStats = stats
        lock.unlock()

        guard !batchEvents.isEmpty else {
            return
        }
        onBatch(MacFSWEventBatch(events: batchEvents, stats: batchStats))
    }

    private func snapshot(message: UnsafePointer<es_message_t>) -> MacFSWFileEvent? {
        let eventType = macfswEventType(message.pointee.event_type)
        guard eventType != .unknown else {
            return nil
        }

        let process = processIdentity(message.pointee.process)
        if config.excludedProcessNames.contains(where: { process.processName.localizedCaseInsensitiveContains($0) }) {
            return nil
        }
        if !config.targetPIDs.isEmpty, !config.targetPIDs.contains(process.pid) {
            return nil
        }
        if !config.targetProcessNames.isEmpty,
           !config.targetProcessNames.contains(where: { process.processName.localizedCaseInsensitiveContains($0) }) {
            return nil
        }

        let paths = eventPaths(message: message)
        guard let targetPath = paths.target else {
            return nil
        }
        if !config.includePaths.isEmpty,
           !config.includePaths.contains(where: { path in eventPaths(paths, contain: path) }) {
            return nil
        }
        if config.excludePaths.contains(where: { path in eventPaths(paths, contain: path) }) {
            return nil
        }

        let timestampNS = UInt64(message.pointee.time.tv_sec) * 1_000_000_000 + UInt64(message.pointee.time.tv_nsec)
        let parameters = eventParameters(message: message)
        let event = MacFSWFileEvent(
            timestampNS: timestampNS,
            eventType: eventType,
            process: process,
            targetPath: targetPath,
            sourcePath: paths.source,
            parameters: parameters,
            fileID: paths.fileID,
            flags: paths.flags,
            uid: UInt32(audit_token_to_euid(message.pointee.process.pointee.audit_token)),
            gid: UInt32(audit_token_to_egid(message.pointee.process.pointee.audit_token)),
            rawEventType: rawEventTypeName(message.pointee.event_type),
            rawEventTypeValue: UInt32(message.pointee.event_type.rawValue),
            rawEventVersion: message.pointee.version
        )
        return event
    }

    private func eventPaths(message: UnsafePointer<es_message_t>) -> (target: String?, source: String?, fileID: UInt64?, flags: UInt64) {
        switch message.pointee.event_type {
        case ES_EVENT_TYPE_NOTIFY_CREATE:
            let create = message.pointee.event.create
            if create.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE {
                return fileSnapshot(create.destination.existing_file)
            }
            let target = joinPath(
                directory: string(create.destination.new_path.dir.pointee.path),
                filename: string(create.destination.new_path.filename)
            )
            return (target, nil, nil, 0)
        case ES_EVENT_TYPE_NOTIFY_WRITE:
            return fileSnapshot(message.pointee.event.write.target)
        case ES_EVENT_TYPE_NOTIFY_UNLINK:
            return fileSnapshot(message.pointee.event.unlink.target)
        case ES_EVENT_TYPE_NOTIFY_SETMODE:
            return fileSnapshot(message.pointee.event.setmode.target)
        case ES_EVENT_TYPE_NOTIFY_SETOWNER:
            return fileSnapshot(message.pointee.event.setowner.target)
        case ES_EVENT_TYPE_NOTIFY_SETFLAGS:
            return fileSnapshot(message.pointee.event.setflags.target)
        case ES_EVENT_TYPE_NOTIFY_SETACL:
            return fileSnapshot(message.pointee.event.setacl.target)
        case ES_EVENT_TYPE_NOTIFY_SETEXTATTR:
            return fileSnapshot(message.pointee.event.setextattr.target)
        case ES_EVENT_TYPE_NOTIFY_DELETEEXTATTR:
            return fileSnapshot(message.pointee.event.deleteextattr.target)
        case ES_EVENT_TYPE_NOTIFY_UTIMES:
            return fileSnapshot(message.pointee.event.utimes.target)
        case ES_EVENT_TYPE_NOTIFY_TRUNCATE:
            return fileSnapshot(message.pointee.event.truncate.target)
        case ES_EVENT_TYPE_NOTIFY_RENAME:
            let rename = message.pointee.event.rename
            let source = fileSnapshot(rename.source)
            let target: String?
            if rename.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE {
                target = string(rename.destination.existing_file.pointee.path)
            } else {
                target = joinPath(
                    directory: string(rename.destination.new_path.dir.pointee.path),
                    filename: string(rename.destination.new_path.filename)
                )
            }
            return (target ?? source.target, source.target, source.fileID, source.flags)
        case ES_EVENT_TYPE_NOTIFY_CLONE:
            let source = fileSnapshot(message.pointee.event.clone.source)
            let target = joinPath(
                directory: string(message.pointee.event.clone.target_dir.pointee.path),
                filename: string(message.pointee.event.clone.target_name)
            )
            return (target, source.target, nil, 0)
        case ES_EVENT_TYPE_NOTIFY_COPYFILE:
            let source = fileSnapshot(message.pointee.event.copyfile.source)
            let target = joinPath(
                directory: string(message.pointee.event.copyfile.target_dir.pointee.path),
                filename: string(message.pointee.event.copyfile.target_name)
            )
            return (target, source.target, nil, UInt64(bitPattern: Int64(message.pointee.event.copyfile.flags)))
        case ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA:
            let first = fileSnapshot(message.pointee.event.exchangedata.file1)
            let second = fileSnapshot(message.pointee.event.exchangedata.file2)
            return (first.target, second.target, first.fileID, first.flags)
        case ES_EVENT_TYPE_NOTIFY_LINK:
            let source = fileSnapshot(message.pointee.event.link.source)
            let target = joinPath(
                directory: string(message.pointee.event.link.target_dir.pointee.path),
                filename: string(message.pointee.event.link.target_filename)
            )
            return (target, source.target, nil, 0)
        default:
            return (nil, nil, nil, 0)
        }
    }

    private func eventParameters(message: UnsafePointer<es_message_t>) -> [MacFSWEventParameter] {
        switch message.pointee.event_type {
        case ES_EVENT_TYPE_NOTIFY_RENAME:
            let rename = message.pointee.event.rename
            let destinationType = rename.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE ? "existing" : "new"
            return [parameter("destination_type", "Destination", destinationType)]
        case ES_EVENT_TYPE_NOTIFY_COPYFILE:
            return [parameter("copy_flags", "Copy Flags", hex(UInt64(bitPattern: Int64(message.pointee.event.copyfile.flags))))]
        case ES_EVENT_TYPE_NOTIFY_SETMODE:
            let setmode = message.pointee.event.setmode
            return [
                parameter("mode", "Mode", octalMode(UInt64(setmode.mode))),
                parameter("current_mode", "Current Mode", octalMode(UInt64(setmode.target.pointee.stat.st_mode))),
            ]
        case ES_EVENT_TYPE_NOTIFY_SETOWNER:
            let setowner = message.pointee.event.setowner
            return [
                parameter("uid", "UID", ownerText(setowner.uid)),
                parameter("gid", "GID", ownerText(setowner.gid)),
                parameter("current_uid", "Current UID", ownerText(setowner.target.pointee.stat.st_uid)),
                parameter("current_gid", "Current GID", ownerText(setowner.target.pointee.stat.st_gid)),
            ]
        case ES_EVENT_TYPE_NOTIFY_SETFLAGS:
            let setflags = message.pointee.event.setflags
            return [
                parameter("flags", "Flags", hex(UInt64(setflags.flags))),
                parameter("current_flags", "Current Flags", hex(UInt64(setflags.target.pointee.stat.st_flags))),
            ]
        case ES_EVENT_TYPE_NOTIFY_SETACL:
            let setacl = message.pointee.event.setacl
            let action = setacl.set_or_clear == ES_SET ? "set" : "clear"
            return [parameter("acl_action", "ACL Action", action)]
        case ES_EVENT_TYPE_NOTIFY_SETEXTATTR:
            return [parameter("xattr", "Extended Attribute", string(message.pointee.event.setextattr.extattr))]
        case ES_EVENT_TYPE_NOTIFY_DELETEEXTATTR:
            return [parameter("xattr", "Extended Attribute", string(message.pointee.event.deleteextattr.extattr))]
        case ES_EVENT_TYPE_NOTIFY_UTIMES:
            let utimes = message.pointee.event.utimes
            return [
                parameter("atime", "Access Time", timespecText(utimes.atime)),
                parameter("mtime", "Modified Time", timespecText(utimes.mtime)),
            ]
        default:
            return []
        }
    }

    private func fileSnapshot(_ file: UnsafePointer<es_file_t>) -> (target: String?, source: String?, fileID: UInt64?, flags: UInt64) {
        let stat = file.pointee.stat
        return (
            string(file.pointee.path),
            nil,
            UInt64(stat.st_ino),
            UInt64(stat.st_flags)
        )
    }

    private func eventPaths(
        _ paths: (target: String?, source: String?, fileID: UInt64?, flags: UInt64),
        contain text: String
    ) -> Bool {
        guard !text.isEmpty else {
            return true
        }
        return [paths.target, paths.source]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(text) }
    }

    private func processIdentity(_ processPointer: UnsafePointer<es_process_t>) -> MacFSWProcessIdentity {
        let process = processPointer.pointee
        let executablePath = string(process.executable.pointee.path)
        return MacFSWProcessIdentity(
            pid: audit_token_to_pid(process.audit_token),
            auditToken: auditTokenString(process.audit_token),
            executablePath: executablePath,
            processName: URL(fileURLWithPath: executablePath).lastPathComponent,
            signingID: string(process.signing_id),
            teamID: string(process.team_id),
            cdhash: cdhashString(process.cdhash),
            isPlatformBinary: process.is_platform_binary
        )
    }

    private func string(_ token: es_string_token_t) -> String {
        guard let data = token.data, token.length > 0 else {
            return ""
        }
        let buffer = UnsafeBufferPointer(start: data, count: token.length)
        let bytes = buffer.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func joinPath(directory: String, filename: String) -> String {
        URL(fileURLWithPath: directory).appendingPathComponent(filename).path
    }

    private func auditTokenString(_ token: audit_token_t) -> String {
        withUnsafeBytes(of: token) { rawBuffer in
            rawBuffer.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func cdhashString(_ cdhash: es_cdhash_t) -> String {
        withUnsafeBytes(of: cdhash) { rawBuffer in
            rawBuffer.map { String(format: "%02x", $0) }.joined()
        }
    }

    private func parameter(_ key: String, _ label: String, _ value: String) -> MacFSWEventParameter {
        MacFSWEventParameter(key: key, label: label, value: value)
    }

    private func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    private func octalMode(_ value: UInt64) -> String {
        let mode = String(value & 0o7777, radix: 8)
        return String(repeating: "0", count: max(0, 4 - mode.count)) + mode
    }

    private func ownerText<T: FixedWidthInteger>(_ value: T) -> String {
        if UInt64(value) == UInt64(UInt32.max) {
            return "unchanged"
        }
        return String(UInt64(value))
    }

    private func timespecText(_ value: timespec) -> String {
        let nanoseconds = String(format: "%09ld", value.tv_nsec)
        return "\(value.tv_sec).\(nanoseconds)"
    }

    private func macfswEventType(_ eventType: es_event_type_t) -> MacFSWEventType {
        switch eventType {
        case ES_EVENT_TYPE_NOTIFY_CREATE: .create
        case ES_EVENT_TYPE_NOTIFY_OPEN: .open
        case ES_EVENT_TYPE_NOTIFY_CLOSE: .close
        case ES_EVENT_TYPE_NOTIFY_WRITE: .write
        case ES_EVENT_TYPE_NOTIFY_RENAME: .rename
        case ES_EVENT_TYPE_NOTIFY_UNLINK: .unlink
        case ES_EVENT_TYPE_NOTIFY_LINK: .link
        case ES_EVENT_TYPE_NOTIFY_CLONE: .clone
        case ES_EVENT_TYPE_NOTIFY_COPYFILE: .copyfile
        case ES_EVENT_TYPE_NOTIFY_TRUNCATE: .truncate
        case ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA: .exchangedata
        case ES_EVENT_TYPE_NOTIFY_SETMODE: .chmod
        case ES_EVENT_TYPE_NOTIFY_SETOWNER: .chown
        case ES_EVENT_TYPE_NOTIFY_SETFLAGS: .setflags
        case ES_EVENT_TYPE_NOTIFY_SETACL: .setacl
        case ES_EVENT_TYPE_NOTIFY_SETEXTATTR: .setextattr
        case ES_EVENT_TYPE_NOTIFY_DELETEEXTATTR: .deleteextattr
        case ES_EVENT_TYPE_NOTIFY_UTIMES: .utimes
        default: .unknown
        }
    }

    private func rawEventTypeName(_ eventType: es_event_type_t) -> String {
        switch eventType {
        case ES_EVENT_TYPE_NOTIFY_CREATE: "ES_EVENT_TYPE_NOTIFY_CREATE"
        case ES_EVENT_TYPE_NOTIFY_OPEN: "ES_EVENT_TYPE_NOTIFY_OPEN"
        case ES_EVENT_TYPE_NOTIFY_CLOSE: "ES_EVENT_TYPE_NOTIFY_CLOSE"
        case ES_EVENT_TYPE_NOTIFY_WRITE: "ES_EVENT_TYPE_NOTIFY_WRITE"
        case ES_EVENT_TYPE_NOTIFY_RENAME: "ES_EVENT_TYPE_NOTIFY_RENAME"
        case ES_EVENT_TYPE_NOTIFY_UNLINK: "ES_EVENT_TYPE_NOTIFY_UNLINK"
        case ES_EVENT_TYPE_NOTIFY_LINK: "ES_EVENT_TYPE_NOTIFY_LINK"
        case ES_EVENT_TYPE_NOTIFY_CLONE: "ES_EVENT_TYPE_NOTIFY_CLONE"
        case ES_EVENT_TYPE_NOTIFY_COPYFILE: "ES_EVENT_TYPE_NOTIFY_COPYFILE"
        case ES_EVENT_TYPE_NOTIFY_TRUNCATE: "ES_EVENT_TYPE_NOTIFY_TRUNCATE"
        case ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA: "ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA"
        case ES_EVENT_TYPE_NOTIFY_SETMODE: "ES_EVENT_TYPE_NOTIFY_SETMODE"
        case ES_EVENT_TYPE_NOTIFY_SETOWNER: "ES_EVENT_TYPE_NOTIFY_SETOWNER"
        case ES_EVENT_TYPE_NOTIFY_SETFLAGS: "ES_EVENT_TYPE_NOTIFY_SETFLAGS"
        case ES_EVENT_TYPE_NOTIFY_SETACL: "ES_EVENT_TYPE_NOTIFY_SETACL"
        case ES_EVENT_TYPE_NOTIFY_SETEXTATTR: "ES_EVENT_TYPE_NOTIFY_SETEXTATTR"
        case ES_EVENT_TYPE_NOTIFY_DELETEEXTATTR: "ES_EVENT_TYPE_NOTIFY_DELETEEXTATTR"
        case ES_EVENT_TYPE_NOTIFY_UTIMES: "ES_EVENT_TYPE_NOTIFY_UTIMES"
        default: "ES_EVENT_TYPE_UNKNOWN_\(eventType.rawValue)"
        }
    }

    private func esEventType(_ eventType: MacFSWEventType) -> es_event_type_t? {
        switch eventType {
        case .create: ES_EVENT_TYPE_NOTIFY_CREATE
        case .open: ES_EVENT_TYPE_NOTIFY_OPEN
        case .close: ES_EVENT_TYPE_NOTIFY_CLOSE
        case .write: ES_EVENT_TYPE_NOTIFY_WRITE
        case .rename: ES_EVENT_TYPE_NOTIFY_RENAME
        case .unlink: ES_EVENT_TYPE_NOTIFY_UNLINK
        case .link: ES_EVENT_TYPE_NOTIFY_LINK
        case .clone: ES_EVENT_TYPE_NOTIFY_CLONE
        case .copyfile: ES_EVENT_TYPE_NOTIFY_COPYFILE
        case .truncate: ES_EVENT_TYPE_NOTIFY_TRUNCATE
        case .exchangedata: ES_EVENT_TYPE_NOTIFY_EXCHANGEDATA
        case .chmod: ES_EVENT_TYPE_NOTIFY_SETMODE
        case .chown: ES_EVENT_TYPE_NOTIFY_SETOWNER
        case .setflags: ES_EVENT_TYPE_NOTIFY_SETFLAGS
        case .setacl: ES_EVENT_TYPE_NOTIFY_SETACL
        case .setextattr: ES_EVENT_TYPE_NOTIFY_SETEXTATTR
        case .deleteextattr: ES_EVENT_TYPE_NOTIFY_DELETEEXTATTR
        case .utimes: ES_EVENT_TYPE_NOTIFY_UTIMES
        case .unknown: nil
        }
    }

    private static func clientCreationFailure(from result: es_new_client_result_t) -> EndpointSecurityClientCreationFailure {
        let code = Int(result.rawValue)
        switch result {
        case ES_NEW_CLIENT_RESULT_ERR_INVALID_ARGUMENT:
            return EndpointSecurityClientCreationFailure(code: code, name: "ES_NEW_CLIENT_RESULT_ERR_INVALID_ARGUMENT", fullDiskAccessRequired: false)
        case ES_NEW_CLIENT_RESULT_ERR_INTERNAL:
            return EndpointSecurityClientCreationFailure(code: code, name: "ES_NEW_CLIENT_RESULT_ERR_INTERNAL", fullDiskAccessRequired: false)
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED:
            return EndpointSecurityClientCreationFailure(code: code, name: "ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED", fullDiskAccessRequired: false)
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED:
            return EndpointSecurityClientCreationFailure(code: code, name: "ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED", fullDiskAccessRequired: true)
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED:
            return EndpointSecurityClientCreationFailure(code: code, name: "ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED", fullDiskAccessRequired: false)
        case ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS:
            return EndpointSecurityClientCreationFailure(code: code, name: "ES_NEW_CLIENT_RESULT_ERR_TOO_MANY_CLIENTS", fullDiskAccessRequired: false)
        default:
            return EndpointSecurityClientCreationFailure(code: code, name: String(describing: result), fullDiskAccessRequired: false)
        }
    }
    #endif
}
