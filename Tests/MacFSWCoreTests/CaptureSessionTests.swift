import Foundation
import SQLite3
import XCTest
@testable import MacFSWCore

final class CaptureSessionTests: XCTestCase {
    func testBatchesAreStoredAndPublishedInDeliveryOrder() async throws {
        let client = FakeCaptureClient()
        let session = try MacFSWCaptureSession.temporary(for: MacFSWResearchSession(), client: client)
        let updates = await session.updates()

        try await session.start(config: MacFSWCaptureConfig())
        for batch in 0..<20 {
            client.deliver(Self.events(batch: batch, count: 5))
        }
        client.finish()

        var appendedPaths: [String] = []
        var finalState: MacFSWCaptureState?
        for await update in updates {
            switch update {
            case .appended(let events, _):
                appendedPaths += events.map(\.targetPath)
            case .stateChanged(let state, _):
                if state == .stopped || state == .failed {
                    finalState = state
                }
            }
            if finalState != nil {
                break
            }
        }

        let expected = (0..<20).flatMap { batch in (0..<5).map { "/tmp/\(batch)-\($0)" } }
        XCTAssertEqual(appendedPaths, expected)
        XCTAssertEqual(finalState, .stopped)
        let stored = try await session.store.events(matching: MacFSWEventQuery())
        XCTAssertEqual(stored.map(\.targetPath), expected)
        XCTAssertEqual(stored.map(\.sequence), (1...100).map(UInt64.init))
        try await session.close()
    }

    func testStopReturnsOnlyAfterBufferedBatchesAreStored() async throws {
        let client = FakeCaptureClient()
        let session = try MacFSWCaptureSession.temporary(for: MacFSWResearchSession(), client: client)
        try await session.start(config: MacFSWCaptureConfig())
        for batch in 0..<200 {
            client.deliver(Self.events(batch: batch, count: 50))
        }
        await session.stop()

        let stored = try await session.store.count(matching: MacFSWEventQuery())
        XCTAssertEqual(stored, 10_000)
        try await session.close()
    }

    func testGracefulStopKeepsEventsSentAfterTheStopRequest() async throws {
        let client = FakeCaptureClient()
        client.tailOnStop = (100..<104).map { Self.events(batch: $0, count: 25) }
        let session = try MacFSWCaptureSession.temporary(for: MacFSWResearchSession(), client: client)
        let updates = await session.updates()
        try await session.start(config: MacFSWCaptureConfig())
        client.deliver(Self.events(batch: 0, count: 10))

        let stopping = Task { await session.stop() }
        var sawStopping = false
        for await update in updates {
            if case .stateChanged(.stopping, _) = update {
                sawStopping = true
                try await session.start(config: MacFSWCaptureConfig())
                let state = await session.state
                XCTAssertEqual(state, .stopping, "starting again must wait for the stop to finish")
            }
            if case .stateChanged(.stopped, _) = update {
                break
            }
        }
        await stopping.value

        XCTAssertTrue(sawStopping)
        let stored = try await session.store.count(matching: MacFSWEventQuery())
        XCTAssertEqual(stored, 110)
        try await session.close()
    }

    func testStopWhileConnectingClosesTheStreamOnceItOpens() async throws {
        let client = FakeCaptureClient(opensImmediately: false)
        let session = try MacFSWCaptureSession.temporary(for: MacFSWResearchSession(), client: client)

        let start = Task { try await session.start(config: MacFSWCaptureConfig()) }
        await client.waitUntilOpenRequested()
        await session.stop()
        client.completeOpen()
        try await start.value

        let state = await session.state
        let isRecording = await session.isRecording
        XCTAssertEqual(state, .stopped)
        XCTAssertFalse(isRecording)
        XCTAssertTrue(client.handleWasStopped)
        try await session.close()
    }

    func testRecordingStopsAtTheConfiguredDuration() async throws {
        let client = FakeCaptureClient()
        let session = try MacFSWCaptureSession.temporary(for: MacFSWResearchSession(), client: client)
        let updates = await session.updates()

        try await session.start(config: MacFSWCaptureConfig(maxCaptureDurationSeconds: 1))
        let started = ContinuousClock.now
        for await update in updates {
            if case .stateChanged(.stopped, _) = update {
                break
            }
        }

        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(900))
        XCTAssertTrue(client.handleWasStopped)
        try await session.close()
    }

    func testStreamErrorMovesSessionToFailed() async throws {
        let client = FakeCaptureClient()
        let session = try MacFSWCaptureSession.temporary(for: MacFSWResearchSession(), client: client)
        let updates = await session.updates()

        try await session.start(config: MacFSWCaptureConfig())
        client.finish(error: MacFSWClientError.backend("ES client died"))

        for await update in updates {
            if case .stateChanged(.failed, let error) = update {
                XCTAssertEqual(error?.userFacingMessage, "ES client died")
                break
            }
        }
        let state = await session.state
        XCTAssertEqual(state, .failed)
        try await session.close()
    }

    func testOpenFailurePropagatesAndMarksFailed() async throws {
        let client = FakeCaptureClient(openError: MacFSWClientError.xpcUnavailable("not installed"))
        let session = try MacFSWCaptureSession.temporary(for: MacFSWResearchSession(), client: client)

        do {
            try await session.start(config: MacFSWCaptureConfig())
            XCTFail("start should throw")
        } catch {
            XCTAssertEqual(error.userFacingMessage, "XPC unavailable: not installed")
        }
        let state = await session.state
        XCTAssertEqual(state, .failed)
        try await session.close()
    }

    func testSaveAndReopenRoundTrips() async throws {
        let client = FakeCaptureClient()
        let metadata = MacFSWResearchSession(name: "Round Trip")
        let session = try MacFSWCaptureSession.temporary(for: metadata, client: client)
        _ = try await session.store.appendReturningEvents(Self.events(batch: 0, count: 3))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfsw-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("trip.macfsw-session")

        try await session.save(metadata, to: url)
        try await session.close()

        let (reopened, reopenedMetadata) = try await MacFSWCaptureSession.open(url, client: client)
        XCTAssertEqual(reopenedMetadata.name, "Round Trip")
        let count = try await reopened.store.count(matching: MacFSWEventQuery())
        XCTAssertEqual(count, 3)
        let stats = await reopened.stats
        XCTAssertEqual(stats.deliveredEvents, 3)
    }

    func testStaleCleanupSkipsStoresOwnedByLiveProcesses() async throws {
        let live = try MacFSWSQLiteEventStore.temporary()
        let liveDirectory = live.url.deletingLastPathComponent()

        let stale = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfsw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        try MacFSWSQLiteEventStore.cleanupStaleTemporaryStores()

        XCTAssertTrue(FileManager.default.fileExists(atPath: liveDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        try await live.cleanupBackingStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDirectory.path))
    }

    private static func events(batch: Int, count: Int) -> [MacFSWFileEvent] {
        let process = MacFSWProcessIdentity(pid: 7, auditToken: "t", executablePath: "/bin/tool", processName: "tool")
        return (0..<count).map {
            MacFSWFileEvent(eventType: .write, process: process, targetPath: "/tmp/\(batch)-\($0)")
        }
    }
}

/// A capture client the test drives by hand: it records the stream
/// callbacks and lets the test deliver batches, finish the stream, and
/// decide when an open request completes.
private final class FakeCaptureClient: MacFSWCaptureClient, @unchecked Sendable {
    private let lock = NSLock()
    private let opensImmediately: Bool
    private let openError: (any Error)?
    /// Like the extension's graceful stop: batches still sent after stop
    /// is requested, before the finish signal.
    var tailOnStop: [[MacFSWFileEvent]] = []
    private var onBatch: (@Sendable (MacFSWEventBatch) -> Void)?
    private var onFinish: (@Sendable ((any Error)?) -> Void)?
    private var pendingOpen: CheckedContinuation<MacFSWCaptureHandle, any Error>?
    private var openRequested: CheckedContinuation<Void, Never>?
    private var stopped = false

    init(opensImmediately: Bool = true, openError: (any Error)? = nil) {
        self.opensImmediately = opensImmediately
        self.openError = openError
    }

    var handleWasStopped: Bool {
        lock.withLock { stopped }
    }

    func health() async throws -> MacFSWCaptureHealth {
        MacFSWCaptureHealth(state: .idle, endpointSecurityAuthorized: true)
    }

    func openCaptureStream(
        config: MacFSWCaptureConfig,
        onBatch: @escaping @Sendable (MacFSWEventBatch) -> Void,
        onFinish: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> MacFSWCaptureHandle {
        if let openError {
            throw openError
        }
        lock.withLock {
            self.onBatch = onBatch
            self.onFinish = onFinish
        }
        if opensImmediately {
            return makeHandle()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let requested = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                pendingOpen = continuation
                defer { openRequested = nil }
                return openRequested
            }
            requested?.resume()
        }
    }

    func waitUntilOpenRequested() async {
        await withCheckedContinuation { continuation in
            let alreadyRequested = lock.withLock { () -> Bool in
                guard pendingOpen == nil else { return true }
                openRequested = continuation
                return false
            }
            if alreadyRequested {
                continuation.resume()
            }
        }
    }

    func completeOpen() {
        let continuation = lock.withLock { () -> CheckedContinuation<MacFSWCaptureHandle, any Error>? in
            defer { pendingOpen = nil }
            return pendingOpen
        }
        continuation?.resume(returning: makeHandle())
    }

    func deliver(_ events: [MacFSWFileEvent]) {
        lock.withLock { onBatch }?(MacFSWEventBatch(events: events, stats: MacFSWCaptureStats()))
    }

    func finish(error: (any Error)? = nil) {
        lock.withLock { onFinish }?(error)
    }

    private func makeHandle() -> MacFSWCaptureHandle {
        MacFSWCaptureHandle { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.stopped = true }
            let tail = self.tailOnStop
            guard !tail.isEmpty else {
                self.finish()
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
                tail.forEach(self.deliver)
                self.finish()
            }
        }
    }
}

final class EventStoreAgentQueryTests: XCTestCase {
    func testProcessSummariesAndEventsHonorQueryAndPaging() async throws {
        let store = try MacFSWSQLiteEventStore.temporary()
        let writer = MacFSWProcessIdentity(pid: 1, auditToken: "a", executablePath: "/bin/writer", processName: "writer")
        let deleter = MacFSWProcessIdentity(pid: 2, auditToken: "b", executablePath: "/bin/deleter", processName: "deleter")
        _ = try await store.appendReturningEvents(
            (0..<5).map { MacFSWFileEvent(eventType: .write, process: writer, targetPath: "/tmp/w\($0)") }
                + [MacFSWFileEvent(eventType: .unlink, process: deleter, targetPath: "/tmp/gone")]
        )

        let deleters = try await store.processSummaries(matching: MacFSWQueryParser.parse("op:unlink"))
        XCTAssertEqual(deleters.map(\.processName), ["deleter"])

        let page = try await store.events(matching: MacFSWQueryParser.parse("op:write"), limit: 2, offset: 2)
        XCTAssertEqual(page.map(\.targetPath), ["/tmp/w2", "/tmp/w3"])
        try await store.cleanupBackingStore()
    }
}

final class CaptureHealthVersionTests: XCTestCase {
    func testHealthFromOlderExtensionsDecodesWithoutAVersion() throws {
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder.macfsw.encode(MacFSWCaptureHealth())) as! [String: Any]
        legacy["extensionVersion"] = nil
        let decoded = try JSONDecoder.macfsw.decode(MacFSWCaptureHealth.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.extensionVersion)

        let current = MacFSWCaptureHealth(extensionVersion: MacFSWComponentVersion(shortVersion: "0.1.8", build: "14"))
        let roundTripped = try JSONDecoder.macfsw.decode(MacFSWCaptureHealth.self, from: JSONEncoder.macfsw.encode(current))
        XCTAssertEqual(roundTripped.extensionVersion?.description, "0.1.8 (14)")
    }
}

final class ReadOnlySessionFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfsw-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOpenedSessionsAreNeverWritten() async throws {
        let url = try await makeSessionFile(name: "Original", events: 2)
        let before = try Data(contentsOf: url)

        let (session, metadata) = try await MacFSWCaptureSession.open(url, client: NeverCalledClient())
        XCTAssertTrue(session.store.isReadOnly)
        XCTAssertEqual(metadata.name, "Original")
        do {
            try await session.start(config: MacFSWCaptureConfig())
            XCTFail("expected readOnly")
        } catch let error as MacFSWCaptureSessionError {
            XCTAssertEqual(error, .readOnly)
        }
        do {
            try await session.clear()
            XCTFail("expected readOnly")
        } catch let error as MacFSWCaptureSessionError {
            XCTAssertEqual(error, .readOnly)
        }

        let copy = directory.appendingPathComponent("copy.macfsw-session")
        try await session.save(MacFSWResearchSession(name: "Renamed"), to: copy)
        try await session.close()

        XCTAssertEqual(try Data(contentsOf: url), before, "the opened file must be byte-for-byte unchanged")
        let (reopened, renamed) = try await MacFSWCaptureSession.open(copy, client: NeverCalledClient())
        XCTAssertEqual(renamed.name, "Renamed")
        let count = try await reopened.store.count(matching: MacFSWEventQuery())
        XCTAssertEqual(count, 2)
    }

    func testFilesWithoutTheCurrentSchemaAreRejected() throws {
        let url = directory.appendingPathComponent("other.macfsw-session")
        try makeForeignSQLiteFile(at: url)
        XCTAssertThrowsError(try MacFSWSessionArchive.openSessionStore(from: url)) { error in
            XCTAssertTrue(error is MacFSWArchiveError, "\(error)")
        }
    }

    private func makeSessionFile(name: String, events: Int) async throws -> URL {
        let store = try MacFSWSQLiteEventStore.temporary()
        let process = MacFSWProcessIdentity(pid: 3, auditToken: "t", executablePath: "/bin/t", processName: "t")
        _ = try await store.appendReturningEvents((0..<events).map {
            MacFSWFileEvent(eventType: .write, process: process, targetPath: "/tmp/\($0)")
        })
        let url = directory.appendingPathComponent("\(name).macfsw-session")
        try await MacFSWSessionArchive.saveSession(MacFSWResearchSession(name: name), from: store, to: url)
        try await store.cleanupBackingStore()
        return url
    }
}

/// A valid SQLite file that is not a MacFSW session.
private func makeForeignSQLiteFile(at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else {
        throw POSIXError(.EIO)
    }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "CREATE TABLE events (id TEXT)", nil, nil, nil)
}

private struct NeverCalledClient: MacFSWCaptureClient {
    func health() async throws -> MacFSWCaptureHealth {
        XCTFail("unexpected health check")
        return MacFSWCaptureHealth()
    }

    func openCaptureStream(
        config: MacFSWCaptureConfig,
        onBatch: @escaping @Sendable (MacFSWEventBatch) -> Void,
        onFinish: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> MacFSWCaptureHandle {
        XCTFail("a read-only session must not open a capture stream")
        throw MacFSWCaptureSessionError.readOnly
    }
}
