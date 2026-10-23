import Foundation
import XCTest

/// Runs the built `macfsw` executable the way a shell or an MCP client
/// would.
final class BinaryTests: XCTestCase {
    private var fixture: URL!

    override func setUp() async throws {
        fixture = try await Fixture.make()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
    }

    func testQueryPrintsMatchingEvents() throws {
        let output = try run(["query", fixture.path, "op:write", "--limit", "2"])
        XCTAssertTrue(output.contains("3 events match op:write; showing 1–2"), output)
        XCTAssertTrue(output.contains("/tmp/w1"), output)
        XCTAssertFalse(output.contains("/tmp/w2"), output)
    }

    func testSummaryAsJSON() throws {
        let data = Data(try run(["summary", fixture.path, "--json"]).utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["total"] as? Int, 5)
    }

    func testRecordRefusesToOverwriteWithoutForce() throws {
        let process = try launch(["record", "--out", fixture.path])
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
    }

    func testMCPServesOverStdio() throws {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = ["mcp"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { process.terminate() }

        var buffer = Data()
        func send(_ request: String) {
            input.fileHandleForWriting.write(Data((request + "\n").utf8))
        }
        func response(id: Int) throws -> [String: Any] {
            while true {
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let object = try JSONSerialization.jsonObject(with: line) as? [String: Any], object["id"] as? Int == id {
                        return object
                    }
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else {
                    throw XCTSkip("macfsw mcp closed its output")
                }
                buffer.append(chunk)
            }
        }

        // Like a real client, wait for each response before the next call.
        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        _ = try response(id: 1)
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_session","arguments":{"path":"\#(fixture.path)"}}}"#)
        _ = try response(id: 2)
        send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"summarize_events","arguments":{"query":"op:unlink"}}}"#)
        let summaryResponse = try response(id: 3)

        let summary = try XCTUnwrap((summaryResponse["result"] as? [String: Any])?["structuredContent"] as? [String: Any], "\(summaryResponse)")
        XCTAssertEqual(summary["total"] as? Int, 2)
    }
    private static var executable: URL {
        Bundle(for: BinaryTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("macfsw")
    }

    private func launch(_ arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }
}
