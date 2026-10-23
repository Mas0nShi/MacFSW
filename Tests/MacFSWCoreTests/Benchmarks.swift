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

/// Query latency on a large store, for the operations the monitor, the
/// sidebar, and the CLI/MCP tools run.
final class QueryBenchmark: XCTestCase {
    func testQueryLatencyOnLargeStore() async throws {
        guard ProcessInfo.processInfo.environment["MACFSW_BENCH"] != nil else { throw XCTSkip("set MACFSW_BENCH") }
        let configuredTotal = ProcessInfo.processInfo.environment["MACFSW_BENCH_EVENTS"].flatMap { Int($0) }
        let total: Int = configuredTotal ?? 500_000
        let store = try MacFSWSQLiteEventStore.temporary()
        var processes: [MacFSWProcessIdentity] = []
        for i in 0..<200 {
            let app = "App\(i % 40)"
            let isApple = i % 3 == 0
            let name: String = i % 7 == 0 ? "mdworker_shared" : app
            let signing: String = isApple ? "com.apple.app\(i)" : "com.vendor.app\(i)"
            let team: String? = isApple ? nil : "TEAM\(i % 9)"
            processes.append(MacFSWProcessIdentity(
                pid: Int32(1000 + i),
                auditToken: "token-\(i)",
                executablePath: "/Applications/\(app).app/Contents/MacOS/\(app)",
                processName: name,
                signingID: signing,
                teamID: team,
                isPlatformBinary: isApple
            ))
        }
        let types: [MacFSWEventType] = [.write, .write, .write, .create, .rename, .unlink, .chmod, .open]
        var generator = SystemRandomNumberGenerator()
        var appended = 0
        let fill = ContinuousClock.now
        while appended < total {
            let batch = (0..<2048).map { i -> MacFSWFileEvent in
                let n = appended + i
                let dir = ["/Users/someone/Library/Caches", "/private/var/folders/xy/T", "/Library/LaunchAgents", "/Users/someone/Documents/Project/src", "/System/Volumes/Data/tmp"][Int(generator.next() % 5)]
                return MacFSWFileEvent(eventType: types[Int(generator.next() % 8)], process: processes[Int(generator.next() % 200)],
                                       targetPath: "\(dir)/item\(n % 5000)/file\(n).dat",
                                       parameters: [MacFSWEventParameter(key: "size", label: "Size", value: "\(n % 4096)")])
            }
            _ = try await store.appendReturningEvents(batch)
            appended += batch.count
        }
        print("BENCH fill \(appended) events in \(Self.milliseconds(since: fill)) ms")
        let all = MacFSWEventQuery()
        let writes = MacFSWQueryParser.parse("op:write")
        let text = MacFSWQueryParser.parse("LaunchAgents")
        let pathLike = MacFSWQueryParser.parse("path:*item42*")
        let process = MacFSWQueryParser.parse("process:mdworker_shared")
        let combined = MacFSWQueryParser.parse("mutation:true apple:false path:/Library")
        var t = ContinuousClock.now
        _ = try await store.count(matching: all)
        print("BENCH count all: \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.count(matching: writes)
        print("BENCH count op:write: \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.count(matching: text)
        print("BENCH count text LaunchAgents (FTS): \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.count(matching: pathLike)
        print("BENCH count path glob (LIKE): \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.count(matching: process)
        print("BENCH count process:mdworker: \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.count(matching: combined)
        print("BENCH count combined: \(Self.milliseconds(since: t)) ms")
        let snapshot = try await store.createResultSnapshot(matching: writes, sortOrder: .oldestFirst)
        t = ContinuousClock.now
        _ = try await store.rowSummaries(in: snapshot, visibleRange: 0..<256)
        print("BENCH rows page at start (op:write): \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.rowSummaries(in: snapshot, visibleRange: (snapshot.visibleCount / 2)..<(snapshot.visibleCount / 2 + 256))
        print("BENCH rows page at middle (op:write): \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.rowSummaries(in: snapshot, visibleRange: (snapshot.visibleCount - 256)..<snapshot.visibleCount)
        print("BENCH rows page at end (op:write): \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.events(matching: all, sortOrder: .newestFirst, limit: 100)
        print("BENCH events newest 100 (CLI default --newest): \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.events(matching: all, limit: 100, offset: 400_000)
        print("BENCH events offset 400k (MCP paging): \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.operationSummaries(matching: all)
        print("BENCH operation summaries all: \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.processSummaries()
        print("BENCH process summaries all (sidebar on open): \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.processSummaries(matching: MacFSWQueryParser.parse("op:unlink"))
        print("BENCH process summaries op:unlink: \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        _ = try await store.distinctValues(for: .processName, matching: writes, limit: 50)
        print("BENCH facet processName for op:write: \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).macfsw-session")
            try await store.copyDatabase(to: url)
            print("BENCH file size \((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int).map { $0 / 1_048_576 } ?? -1) MB")
            try? FileManager.default.removeItem(at: url)
        }
        print("BENCH save copy (VACUUM INTO): \(Self.milliseconds(since: t)) ms")
        t = ContinuousClock.now
        try await store.clear()
        print("BENCH clear: \(Self.milliseconds(since: t)) ms")
        try await store.cleanupBackingStore()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now)
        return Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
