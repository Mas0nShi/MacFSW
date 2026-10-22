import Foundation

/// The display order for a list ranked by a count that changes several
/// times a second while recording (processes, operations). Rows hold their
/// places through noise and move only for a real change:
///
/// - A row passes the one above it only once it leads by more than
///   `margin`, so near-equal counts do not swap back and forth.
/// - Rows move at most once per `interval`, so moves read as occasional
///   animated steps rather than constant motion.
///
/// Rows not shown before join at the end and rise by the same rule.
struct StableRanking<ID: Hashable> {
    var interval: Duration = .seconds(1)
    var margin = 0.1
    private(set) var order: [ID] = []
    private var lastMove: ContinuousClock.Instant?

    struct Update {
        /// What to show now.
        var order: [ID]
        /// Whether rows moved: animate this one.
        var moved: Bool
        /// When a held-back move may be shown; update again then.
        var retryAfter: Duration?
    }

    /// `ranked` is the list best first, with each row's count.
    mutating func update(_ ranked: [(id: ID, count: Int)], now: ContinuousClock.Instant = .now) -> Update {
        let counts = Dictionary(ranked.map { ($0.id, $0.count) }, uniquingKeysWith: { first, _ in first })
        guard !order.isEmpty else {
            order = ranked.map(\.id)
            return Update(order: order, moved: false)
        }
        let kept = order.filter { counts[$0] != nil }
        let keptSet = Set(kept)
        let inPlace = kept + ranked.map(\.id).filter { !keptSet.contains($0) }
        let proposed = settled(inPlace, counts: counts)
        guard proposed != inPlace else {
            order = inPlace
            return Update(order: order, moved: false)
        }
        if let lastMove, now - lastMove < interval {
            order = inPlace
            return Update(order: order, moved: false, retryAfter: lastMove + interval - now)
        }
        lastMove = now
        order = proposed
        return Update(order: order, moved: true)
    }

    /// Lets rows that clearly outrank the row above them pass it. A pass
    /// can never be undone by the same rule, so this terminates.
    private func settled(_ order: [ID], counts: [ID: Int]) -> [ID] {
        var order = order
        var passed = true
        while passed {
            passed = false
            for index in order.indices.dropFirst() {
                let above = Double(counts[order[index - 1]] ?? 0)
                let below = Double(counts[order[index]] ?? 0)
                if below > above * (1 + margin) + 1 {
                    order.swapAt(index - 1, index)
                    passed = true
                }
            }
        }
        return order
    }
}
