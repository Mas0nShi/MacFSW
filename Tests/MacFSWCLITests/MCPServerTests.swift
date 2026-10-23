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

    /// Codex declares object-valued experimental capabilities, which the
    /// SDK alone rejects (swift-sdk#287).
    func testHandshakeAcceptsObjectValuedExperimentalCapabilities() async throws {
        let workspace = Workspace(client: MacFSWXPCCaptureClient(serviceName: "invalid.macfsw.test", healthTimeoutSeconds: 1), appVersion: "test")
        let server = await MacFSWMCPServer.make(workspace: workspace)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: InitializeCompatibleTransport(serverTransport))
        try await clientTransport.connect()

        let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/sandbox":{"enabled":true}},"elicitation":{}},"clientInfo":{"name":"codex-mcp-client","version":"0.163.0"}}}"#
        try await clientTransport.send(Data(initialize.utf8))
        var responses = await clientTransport.receive().makeAsyncIterator()
        let next = try await responses.next()
        let response = try XCTUnwrap(next)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertNil(json["error"], String(decoding: response, as: UTF8.self))
        XCTAssertNotNil(json["result"])

        let other = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":{"experimental":{"a":1}}}}"#.utf8)
        XCTAssertEqual(InitializeCompatibleTransport.decodable(other), other)

        await clientTransport.disconnect()
        await server.stop()
    }

    func testParsesTheActivatedExtensionFromSystemExtensionsList() {
        let listing = """
        2 extension(s)
        --- com.apple.system_extension.endpoint_security
        enabled\tactive\tteamID\tbundleID (version)\tname\t[state]
        \t\tUYF535Y9QZ\tcom.mas0n.MacFSW.EndpointExtension (0.1.8/13)\tMacFSW Endpoint Extension\t[terminated waiting to uninstall on reboot]
        *\t*\tUYF535Y9QZ\tcom.mas0n.MacFSW.EndpointExtension (0.1.8/14)\tMacFSW Endpoint Extension\t[activated enabled]
        """
        let version = SystemExtensionsList.parseActivatedVersion(of: "com.mas0n.MacFSW.EndpointExtension", in: listing)
        XCTAssertEqual(version, MacFSWComponentVersion(shortVersion: "0.1.8", build: "14"))
        XCTAssertNil(SystemExtensionsList.parseActivatedVersion(of: "com.other.Extension", in: listing))
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
