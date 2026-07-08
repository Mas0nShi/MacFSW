import Foundation
import XCTest

@testable import MacFSWAnalysis

/// Proves the LLM client delivers SSE deltas INCREMENTALLY — as the server
/// emits them — rather than buffering the whole response and replaying the
/// tokens after completion.
final class LLMClientStreamingTests: XCTestCase {
    func testStreamDeliversDeltasIncrementally() async throws {
        let events = [
            #"{"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"{"choices":[{"delta":{"content":" wor"}}]}"#,
            #"{"choices":[{"delta":{"content":"ld"}}]}"#,
        ]
        let gap: TimeInterval = 0.5
        let server = try SlowSSEServer(
            eventPayloads: events,
            gapBetweenEvents: gap
        )
        defer { server.stop() }

        var settings = MacFSWLLMSettings()
        settings.apiKey = "test-key"
        settings.model = "test-model"
        settings.baseURL = "http://127.0.0.1:\(server.port)"
        settings.endpoint = .chatCompletions
        settings.streamResponses = true

        let client = MacFSWLLMClient()
        let request = MacFSWLLMRequest(settings: settings, systemPrompt: "s", userPrompt: "u")

        let start = Date()
        var arrivals: [(elapsed: TimeInterval, text: String)] = []
        for try await delta in try await client.streamAnalysis(request: request) {
            arrivals.append((Date().timeIntervalSince(start), delta.text))
        }

        XCTAssertEqual(arrivals.map(\.text), ["Hello", " wor", "ld"])

        // The server emits events at ~0s, 0.5s, and 1.0s, then closes. Real
        // streaming means the first delta arrives long before the response
        // completes, and the deltas are spread over the emission window —
        // buffered delivery would cluster all three after ~1s.
        XCTAssertLessThan(
            arrivals[0].elapsed, 0.4,
            "first delta must arrive before the response completes (arrivals: \(arrivals))"
        )
        XCTAssertGreaterThan(
            arrivals[2].elapsed - arrivals[0].elapsed, 0.6,
            "deltas must be spread across the server's emission window (arrivals: \(arrivals))"
        )
    }
}

/// Minimal loopback HTTP server that answers one request with an SSE stream,
/// sleeping between events so incremental delivery is observable.
final class SlowSSEServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32

    init(eventPayloads: [String], gapBetweenEvents: TimeInterval) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(.EIO)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                _ = getsockname(fd, sockaddrPointer, &length)
            }
        }
        listenFD = fd
        port = UInt16(bigEndian: boundAddress.sin_port)
        DispatchQueue.global().async {
            let clientFD = accept(fd, nil, nil)
            guard clientFD >= 0 else {
                return
            }
            Self.readFullRequest(clientFD)
            Self.write(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
                to: clientFD
            )
            for (index, payload) in eventPayloads.enumerated() {
                if index > 0 {
                    Thread.sleep(forTimeInterval: gapBetweenEvents)
                }
                Self.write("data: \(payload)\n\n", to: clientFD)
            }
            Self.write("data: [DONE]\n\n", to: clientFD)
            close(clientFD)
        }
    }

    func stop() {
        close(listenFD)
    }

    private static func readFullRequest(_ fd: Int32) {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else {
                return
            }
            received.append(buffer, count: count)
            guard let headerEnd = received.range(of: Data("\r\n\r\n".utf8)) else {
                continue
            }
            let headers = String(data: received[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
            let contentLength = headers
                .split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            if received.count - headerEnd.upperBound >= contentLength {
                return
            }
        }
    }

    private static func write(_ string: String, to fd: Int32) {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { pointer in
                Darwin.write(fd, pointer.baseAddress, pointer.count)
            }
            guard written > 0 else {
                return
            }
            offset += written
        }
    }
}
