import Foundation
import MacFSWCore
import XCTest
@testable import MacFSWCommands

final class WorkspaceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfsw-commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testQueriesOverASavedSession() async throws {
        let fixture = try await makeFixture()
        let workspace = Workspace(client: StubCaptureClient(), appVersion: "test")
        let info = try await workspace.open(fixture)
        XCTAssertEqual(info.source, .file)
        XCTAssertEqual(info.events, 6)

        let queries = try await workspace.queries()
        let page = try await queries.events(matching: "op:write", limit: 2, offset: 1)
        XCTAssertEqual(page.total, 4)
        XCTAssertEqual(page.events.map(\.path), ["/tmp/w1", "/tmp/w2"])
        XCTAssertEqual(page.diagnostics, [])

        let healed = try await queries.events(matching: "porcess:writer")
        XCTAssertFalse(healed.diagnostics.isEmpty)

        let processes = try await queries.processes(matching: "op:unlink")
        XCTAssertEqual(processes.processes.map(\.name), ["deleter"])

        let summary = try await queries.summary()
        XCTAssertEqual(summary.total, 6)
        XCTAssertEqual(summary.operations.first, CountedValue(value: "write", count: 4))
        XCTAssertEqual(summary.topProcesses.first, CountedValue(value: "writer", count: 4))

        let event = try await queries.event(id: page.events[0].id)
        XCTAssertEqual(event.targetPath, "/tmp/w1")
        do {
            _ = try await queries.event(id: UUID())
            XCTFail("expected eventNotFound")
        } catch let error as CommandError {
            guard case .eventNotFound = error else { return XCTFail("\(error)") }
        }
    }

    func testCaptureNeverWritesIntoAnOpenedFileAndSaveRefusesToOverwrite() async throws {
        let fixture = try await makeFixture()
        let workspace = Workspace(client: StubCaptureClient(), appVersion: "test")
        _ = try await workspace.open(fixture)

        let recording = try await workspace.startCapture(CaptureRequest())
        XCTAssertEqual(recording.source, .capture)
        XCTAssertEqual(recording.events, 0)
        XCTAssertEqual(recording.captureState, .recording)

        let stopped = try await workspace.stopCapture()
        XCTAssertEqual(stopped.captureState, .stopped)

        do {
            _ = try await workspace.save(to: fixture)
            XCTFail("expected fileExists")
        } catch let error as CommandError {
            XCTAssertEqual(error, .fileExists(fixture.path))
        }
        let copy = directory.appendingPathComponent("copy.macfsw-session")
        let saved = try await workspace.save(to: copy)
        XCTAssertEqual(saved.events, 0)

        let reopened = Workspace(client: StubCaptureClient(), appVersion: "test")
        let original = try await reopened.open(fixture)
        XCTAssertEqual(original.events, 6, "the opened file must be untouched")
    }

    func testQueryingWithoutASessionExplainsWhatToDo() async throws {
        let workspace = Workspace(client: StubCaptureClient(), appVersion: "test")
        do {
            _ = try await workspace.queries()
            XCTFail("expected noActiveSession")
        } catch let error as CommandError {
            XCTAssertEqual(error, .noActiveSession)
        }
    }

    func testStatusReportsAnUnreachableExtension() async {
        let workspace = Workspace(client: StubCaptureClient(healthError: MacFSWClientError.xpcUnavailable("no service")), appVersion: "test")
        let status = await workspace.status()
        XCTAssertFalse(status.extension.reachable)
        XCTAssertNil(status.session)
    }

    func testCaptureRequestMapsOntoTheCaptureConfig() {
        var request = CaptureRequest()
        request.durationSeconds = 45
        request.excludeProcessNames = ["Spotlight"]
        let config = request.config
        XCTAssertEqual(config.maxCaptureDurationSeconds, 45)
        XCTAssertTrue(config.excludedProcessNames.contains("Spotlight"))
        XCTAssertTrue(config.excludedProcessNames.contains("MacFSW"), "keeps excluding MacFSW itself")
    }

    private func makeFixture() async throws -> URL {
        let store = try MacFSWSQLiteEventStore.temporary()
        let writer = MacFSWProcessIdentity(pid: 1, auditToken: "a", executablePath: "/bin/writer", processName: "writer", signingID: "com.example.writer")
        let deleter = MacFSWProcessIdentity(pid: 2, auditToken: "b", executablePath: "/bin/deleter", processName: "deleter")
        _ = try await store.appendReturningEvents(
            (0..<4).map { MacFSWFileEvent(eventType: .write, process: writer, targetPath: "/tmp/w\($0)") }
                + (0..<2).map { MacFSWFileEvent(eventType: .unlink, process: deleter, targetPath: "/tmp/gone\($0)") }
        )
        let url = directory.appendingPathComponent("fixture.macfsw-session")
        try await MacFSWSessionArchive.saveSession(MacFSWResearchSession(name: "Fixture"), from: store, to: url)
        try await store.cleanupBackingStore()
        return url
    }
}

/// Accepts every capture request and never delivers events.
private struct StubCaptureClient: MacFSWCaptureClient {
    var healthError: (any Error)?

    func health() async throws -> MacFSWCaptureHealth {
        if let healthError {
            throw healthError
        }
        return MacFSWCaptureHealth(state: .idle, endpointSecurityAuthorized: true, message: "ok")
    }

    func openCaptureStream(
        config: MacFSWCaptureConfig,
        onBatch: @escaping @Sendable (MacFSWEventBatch) -> Void,
        onFinish: @escaping @Sendable ((any Error)?) -> Void
    ) async throws -> MacFSWCaptureHandle {
        MacFSWCaptureHandle { onFinish(nil) }
    }
}
