import MacFSWCore
import XCTest
@testable import MacFSWApp

@MainActor
final class ProcessSidebarStoreTests: XCTestCase {
    func testCountsUpdateAtOnceWhileReorderingIsThrottled() async throws {
        let store = ProcessSidebarStore()
        store.update(with: Self.events("alpha", count: 3) + Self.events("beta", count: 1))
        try await waitUntil { store.groupOrder == ["alpha", "beta"] }

        // The first move after a quiet period shows at once.
        store.update(with: Self.events("beta", count: 5))
        try await waitUntil { store.groupOrder == ["beta", "alpha"] }

        // The next one keeps the rows in place while counts update...
        store.update(with: Self.events("alpha", count: 10))
        try await waitUntil { store.filteredProcessGroups.first { $0.id == "alpha" }?.eventCount == 13 }
        XCTAssertEqual(store.groupOrder, ["beta", "alpha"])
        // ...and reorders once the throttle allows.
        try await waitUntil(timeout: .seconds(2)) { store.groupOrder == ["alpha", "beta"] }
    }

    func testSearchReordersImmediately() async throws {
        let store = ProcessSidebarStore()
        store.update(with: Self.events("alpha", count: 3) + Self.events("beta", count: 1))
        try await waitUntil { store.groupOrder == ["alpha", "beta"] }
        store.update(with: Self.events("beta", count: 5))
        try await waitUntil { store.groupOrder == ["beta", "alpha"] }

        store.update(with: Self.events("alpha", count: 10))
        store.processSearchText = "a"
        try await waitUntil(timeout: .milliseconds(500)) { store.groupOrder == ["alpha", "beta"] }
    }

    private static func events(_ name: String, count: Int) -> [MacFSWFileEvent] {
        let process = MacFSWProcessIdentity(pid: name == "alpha" ? 1 : 2, auditToken: name, executablePath: "/bin/\(name)", processName: name)
        return (0..<count).map { MacFSWFileEvent(eventType: .write, process: process, targetPath: "/tmp/\(name)-\($0)") }
    }

    private func waitUntil(timeout: Duration = .seconds(1), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("Timed out waiting for condition")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private extension ProcessSidebarStore {
    var groupOrder: [String] {
        filteredProcessGroups.map(\.id)
    }
}
