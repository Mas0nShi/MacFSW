import Foundation
import XCTest
@testable import MacFSWCore

/// Opt-in throughput benchmarks: `MACFSW_BENCH=1 swift test -c release
/// -Xswiftc -enable-testing --filter Benchmark`. Skipped otherwise.
///
/// Store ingest throughput as the store grows.
final class IngestBenchmark: XCTestCase {
    func testIngestThroughput() async throws {
        guard ProcessInfo.processInfo.environment["MACFSW_BENCH"] != nil else { throw XCTSkip("set MACFSW_BENCH") }
        let store = try MacFSWSQLiteEventStore.temporary()
        let process = MacFSWProcessIdentity(pid: 42, auditToken: "audit", executablePath: "/usr/bin/tool", processName: "tool", signingID: "com.example.tool", teamID: "TEAM")
        let batch = 256, total = 100_000
        var report: [String] = []
        var segmentStart = ContinuousClock.now
        let runStart = ContinuousClock.now
        var appended = 0
        while appended < total {
            let events = (0..<batch).map { i in
                MacFSWFileEvent(eventType: .write, process: process, targetPath: "/Users/someone/Library/Caches/com.example/\(appended + i).db",
                                parameters: [MacFSWEventParameter(key: "size", label: "Size", value: "\(i)")])
            }
            _ = try await store.appendReturningEvents(events)
            appended += batch
            if appended % 20_000 < batch {
                let elapsed = ContinuousClock.now - segmentStart
                report.append("\(appended): \(Int(Double(20_000) / (Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds)))) ev/s")
                segmentStart = ContinuousClock.now
            }
        }
        let runDuration = ContinuousClock.now - runStart
        let totalSeconds = Double(runDuration.components.seconds) + Double(runDuration.components.attoseconds) / 1e18
        print("BENCH total \(Int(Double(appended) / totalSeconds)) ev/s | " + report.joined(separator: " | "))
        try await store.cleanupBackingStore()
    }
}

final class TransportBenchmark: XCTestCase {
    func testBatchCodingThroughput() throws {
        guard ProcessInfo.processInfo.environment["MACFSW_BENCH"] != nil else { throw XCTSkip("set MACFSW_BENCH") }
        let process = MacFSWProcessIdentity(pid: 42, auditToken: "audit-token-0123456789", executablePath: "/usr/bin/tool", processName: "tool", signingID: "com.example.tool", teamID: "TEAM", cdhash: "abcdef0123456789")
        let batch = MacFSWEventBatch(events: (0..<256).map { i in
            MacFSWFileEvent(eventType: .write, process: process, targetPath: "/Users/someone/Library/Caches/com.example/\(i).db",
                            parameters: [MacFSWEventParameter(key: "size", label: "Size", value: "\(i)"), MacFSWEventParameter(key: "mode", label: "Mode", value: "0644")])
        }, stats: MacFSWCaptureStats())
        let rounds = 400
        func measure(_ name: String, _ encode: () throws -> Data, _ decode: (Data) throws -> Void) rethrows {
            let data = try encode()
            let start = ContinuousClock.now
            for _ in 0..<rounds { try decode(try encode()) }
            let seconds = Double((ContinuousClock.now - start).components.attoseconds) / 1e18 + Double((ContinuousClock.now - start).components.seconds)
            print("BENCH \(name): \(Int(Double(rounds * 256) / seconds)) ev/s round-trip, \(data.count / 256) bytes/event")
        }
        try measure("json", { try JSONEncoder.macfsw.encode(batch) }, { _ = try JSONDecoder.macfsw.decode(MacFSWEventBatch.self, from: $0) })
        let plistEncoder = PropertyListEncoder(); plistEncoder.outputFormat = .binary
        try measure("binary plist", { try plistEncoder.encode(batch) }, { _ = try PropertyListDecoder().decode(MacFSWEventBatch.self, from: $0) })
    }
}
