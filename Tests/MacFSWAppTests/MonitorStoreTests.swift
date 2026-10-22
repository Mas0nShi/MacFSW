import Foundation
import MacFSWCore
import XCTest
@testable import MacFSWApp

@MainActor
final class MonitorStoreTests: XCTestCase {
    private var eventStore: MacFSWSQLiteEventStore!
    private var monitor: MonitorStore!

    override func setUp() async throws {
        eventStore = try MacFSWSQLiteEventStore.temporary()
        let defaults = UserDefaults(suiteName: "MonitorStoreTests-\(UUID().uuidString)")!
        monitor = MonitorStore(
            eventStore: eventStore,
            processSidebar: ProcessSidebarStore(),
            queryHistory: QueryHistoryStore(defaults: defaults)
        )
    }

    override func tearDown() async throws {
        monitor.cancelAllWork()
        try await eventStore.cleanupBackingStore()
    }

    func testFilterRefreshCountsAndCachesMatchingRows() async throws {
        _ = try await eventStore.appendReturningEvents(
            Self.events(.write, count: 3) + Self.events(.unlink, count: 2)
        )

        monitor.queryText = "op:unlink"
        await monitor.refreshFilteredEvents()

        XCTAssertEqual(monitor.visibleEventCount, 2)
        XCTAssertFalse(monitor.isApplyingFilter)
        XCTAssertEqual(monitor.cachedRow(at: 0)?.eventType, .unlink)
        XCTAssertEqual(monitor.cachedRow(at: 1)?.eventType, .unlink)
        XCTAssertNil(monitor.cachedRow(at: 2))
    }

    func testLatestFilterRefreshWins() async throws {
        _ = try await eventStore.appendReturningEvents(
            Self.events(.write, count: 4) + Self.events(.unlink, count: 1)
        )

        monitor.queryText = "op:write"
        let stale = Task { await monitor.refreshFilteredEvents() }
        monitor.queryText = "op:unlink"
        await monitor.refreshFilteredEvents()
        await stale.value

        XCTAssertEqual(monitor.visibleEventCount, 1)
        XCTAssertEqual(monitor.activeQuery.text, "op:unlink")
    }

    func testLiveIngestAppendsMatchingRowsAtTheTail() async throws {
        _ = try await eventStore.appendReturningEvents(Self.events(.write, count: 2))
        monitor.queryText = "op:write"
        await monitor.refreshFilteredEvents()
        XCTAssertEqual(monitor.visibleEventCount, 2)

        let appended = try await eventStore.appendReturningEvents(
            Self.events(.write, count: 3, pathPrefix: "/tmp/new") + Self.events(.unlink, count: 4)
        )
        monitor.ingest(appended.events)
        try await waitUntil { self.monitor.visibleEventCount == 5 }

        XCTAssertEqual(monitor.totalMatchingEventCount, 5)
        XCTAssertEqual(monitor.cachedRow(at: 4)?.targetPath, "/tmp/new-2")
        XCTAssertEqual(monitor.unseenEventCount, 0)
    }

    func testPausedViewCountsUnseenEventsWithoutRendering() async throws {
        await monitor.refreshFilteredEvents()
        monitor.followMode = .paused

        let appended = try await eventStore.appendReturningEvents(Self.events(.write, count: 3))
        monitor.ingest(appended.events)

        XCTAssertEqual(monitor.unseenEventCount, 3)
        XCTAssertEqual(monitor.visibleEventCount, 0)
    }

    func testPinningAProcessShowsUpInTheQueryAndFilters() async throws {
        let other = MacFSWProcessIdentity(pid: 77, auditToken: "o", executablePath: "/bin/other", processName: "other")
        _ = try await eventStore.appendReturningEvents(
            Self.events(.write, count: 3) + [MacFSWFileEvent(eventType: .write, process: other, targetPath: "/tmp/o")]
        )
        monitor.queryText = "op:write"

        monitor.pinProcess(77)
        try await waitUntil { self.monitor.visibleEventCount == 1 }
        XCTAssertEqual(monitor.queryText, "op:write pid:77")
        XCTAssertEqual(monitor.pinnedPID, 77)

        monitor.pinProcess(nil)
        try await waitUntil { self.monitor.visibleEventCount == 4 }
        XCTAssertEqual(monitor.queryText, "op:write")
        XCTAssertNil(monitor.pinnedPID)
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func events(_ type: MacFSWEventType, count: Int, pathPrefix: String = "/tmp/file") -> [MacFSWFileEvent] {
        let process = MacFSWProcessIdentity(pid: 9, auditToken: "t", executablePath: "/bin/tool", processName: "tool")
        return (0..<count).map {
            MacFSWFileEvent(eventType: type, process: process, targetPath: "\(pathPrefix)-\($0)")
        }
    }
}
