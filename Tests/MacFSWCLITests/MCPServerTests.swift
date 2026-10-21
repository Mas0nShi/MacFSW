import Foundation
import MacFSWCommands
import MacFSWCore
import MCP
import XCTest
@testable import MacFSWCLI

final class MCPServerTests: XCTestCase {
    private var fixture: URL!

    override func setUp() async throws {
        fixture = try await Fixture.make()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
    }

    func testToolsOverAnMCPClientConnection() async throws {
        let workspace = Workspace(client: MacFSWXPCCaptureClient(serviceName: "invalid.macfsw.test", healthTimeoutSeconds: 1), appVersion: "test")
        let server = await MacFSWMCPServer.make(workspace: workspace)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        let initialized = try await client.connect(transport: clientTransport)
        XCTAssertEqual(initialized.instructions, MacFSWMCPServer.instructions)

        let (tools, _) = try await client.listTools()
        XCTAssertEqual(Set(tools.map(\.name)), [
            "get_status", "start_capture", "stop_capture", "open_session", "save_session",
            "close_session", "summarize_events", "list_processes", "query_events", "get_event",
        ])

        let noSession = try await client.callTool(name: "query_events")
        XCTAssertEqual(noSession.isError, true)

        let opened = try await client.callTool(name: "open_session", arguments: ["path": .string(fixture.path)])
        XCTAssertNotEqual(opened.isError, true)

        let page: EventPage = try decode(try await client.callTool(
            name: "query_events",
            arguments: ["query": "op:unlink", "order": "newest", "limit": 1]
        ))
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.events.map(\.path), ["/tmp/gone1"])

        let event: MacFSWFileEvent = try decode(try await client.callTool(
            name: "get_event",
            arguments: ["id": .string(page.events[0].id.uuidString)]
        ))
        XCTAssertEqual(event.process.processName, "deleter")

        let badID = try await client.callTool(name: "get_event", arguments: ["id": "nope"])
        XCTAssertEqual(badID.isError, true)

        await client.disconnect()
        await server.stop()
    }

    func testQuerySyntaxDescriptionListsEveryCatalogField() {
        for descriptor in MacFSWQueryFieldCatalog.descriptors {
            XCTAssertTrue(MacFSWMCPServer.querySyntax.contains("- \(descriptor.canonicalKey)"), descriptor.canonicalKey)
        }
    }

    private func decode<T: Decodable>(_ result: (content: [Tool.Content], isError: Bool?)) throws -> T {
        XCTAssertNotEqual(result.isError, true)
        guard case .text(let text, _, _) = try XCTUnwrap(result.content.first) else {
            throw XCTSkip("expected text content")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text.utf8))
    }
}

enum Fixture {
    static func make() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macfsw-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try MacFSWSQLiteEventStore.temporary()
        let writer = MacFSWProcessIdentity(pid: 1, auditToken: "a", executablePath: "/bin/writer", processName: "writer")
        let deleter = MacFSWProcessIdentity(pid: 2, auditToken: "b", executablePath: "/bin/deleter", processName: "deleter")
        _ = try await store.appendReturningEvents(
            (0..<3).map { MacFSWFileEvent(eventType: .write, process: writer, targetPath: "/tmp/w\($0)") }
                + (0..<2).map { MacFSWFileEvent(eventType: .unlink, process: deleter, targetPath: "/tmp/gone\($0)") }
        )
        let url = directory.appendingPathComponent("fixture.macfsw-session")
        try await MacFSWSessionArchive.saveSession(MacFSWResearchSession(name: "Fixture"), from: store, to: url)
        try await store.cleanupBackingStore()
        return url
    }
}
