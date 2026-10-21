import Darwin
import Foundation

/// An exclusive `flock` on a marker file that tells other processes a
/// temporary store directory is still in use. The kernel drops the lock
/// when the owning process exits, however it exits, so a lock that can be
/// acquired means the directory is stale.
final class TemporaryDirectoryLock: @unchecked Sendable {
    private static let fileName = ".owner.lock"
    private let lock = NSLock()
    private var descriptor: Int32

    init(holding directory: URL) throws {
        let path = directory.appendingPathComponent(Self.fileName).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(descriptor)
            throw POSIXError(code)
        }
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else {
            return
        }
        close(descriptor)
        descriptor = -1
    }

    /// Whether a live process holds the lock in `directory`. Directories
    /// without a marker file predate locking and count as unheld.
    static func isHeld(in directory: URL) -> Bool {
        let path = directory.appendingPathComponent(fileName).path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK
    }
}
