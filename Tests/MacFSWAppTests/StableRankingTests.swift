import XCTest
@testable import MacFSWApp

final class StableRankingTests: XCTestCase {
    func testFirstRankingAndNewRowsShowAtOnce() {
        var ranking = StableRanking<String>()
        XCTAssertEqual(ranking.update([("a", 5), ("b", 3)]).order, ["a", "b"])
        let update = ranking.update([("a", 5), ("b", 3), ("c", 1)])
        XCTAssertEqual(update.order, ["a", "b", "c"])
        XCTAssertFalse(update.moved)
    }

    func testNearTiesHoldTheirPlaces() {
        var ranking = StableRanking<String>()
        ranking.update([("a", 100), ("b", 99)])
        let update = ranking.update([("b", 105), ("a", 100)])
        XCTAssertEqual(update.order, ["a", "b"])
        XCTAssertFalse(update.moved)
    }

    func testClearLeadsMoveAtMostOncePerInterval() {
        let start = ContinuousClock.now
        var ranking = StableRanking<String>()
        ranking.update([("a", 10), ("b", 1), ("c", 1)], now: start)

        let first = ranking.update([("b", 30), ("a", 10), ("c", 1)], now: start)
        XCTAssertEqual(first.order, ["b", "a", "c"])
        XCTAssertTrue(first.moved)

        let held = ranking.update([("c", 90), ("b", 30), ("a", 10)], now: start + .milliseconds(300))
        XCTAssertEqual(held.order, ["b", "a", "c"])
        XCTAssertEqual(held.retryAfter, .milliseconds(700))

        let later = ranking.update([("c", 90), ("b", 30), ("a", 10)], now: start + .seconds(1))
        XCTAssertEqual(later.order, ["c", "b", "a"])
        XCTAssertTrue(later.moved)
    }
}
