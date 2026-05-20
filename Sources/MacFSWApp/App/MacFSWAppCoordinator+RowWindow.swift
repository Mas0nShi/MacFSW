import AppKit
import Combine
import Darwin
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import UniformTypeIdentifiers

extension MacFSWAppCoordinator {
    func cachedRow(at row: Int) -> MacFSWEventRowSummary? {
        markRowPageAccess(row / rowPageSize)
        return rowCache[row]
    }

    func requestRows(_ range: Range<Int>) {
        guard visibleEventCount > 0 else {
            return
        }
        let lowerBound = max(0, min(visibleEventCount, range.lowerBound))
        let upperBound = max(lowerBound, min(visibleEventCount, range.upperBound))
        guard lowerBound < upperBound else {
            return
        }
        lastRequestedRowRange = lowerBound..<upperBound

        let expandedLower = max(0, lowerBound - 120)
        let expandedUpper = min(visibleEventCount, upperBound + 240)
        loadPages(for: expandedLower..<expandedUpper)
    }

    func liveEdgeChanged(_ isAtLiveEdge: Bool) {
        isViewingLiveEdge = isAtLiveEdge
        if isAtLiveEdge, followMode == .live {
            unseenEventCount = 0
        }
    }

    func preloadRowsForCurrentViewport() {
        guard visibleEventCount > 0 else {
            return
        }
        if followMode == .live {
            let lower = max(0, visibleEventCount - 240)
            requestRows(lower..<visibleEventCount)
        } else {
            requestRows(0..<min(visibleEventCount, 240))
        }
    }

    func resetRowCache(resetTable: Bool) {
        queryGeneration += 1
        operationSummaryTask?.cancel()
        operationSummaryTask = nil
        cancelRowLoads()
        rowCache.removeAll(keepingCapacity: true)
        loadedRowPages.removeAll(keepingCapacity: true)
        inFlightRowPages.removeAll(keepingCapacity: true)
        rowPageAccessTicks.removeAll(keepingCapacity: true)
        lastRequestedRowRange = 0..<0
        pendingVisibleMatchCount = 0
        pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
        rowCacheVersion += 1
        rowCacheResetSerial += 1
        if resetTable {
            tableResetSerial += 1
        }
    }

    func visibleCount(totalCount: Int, query: MacFSWEventQuery) -> Int {
        query.visibleCount(totalCount: totalCount)
    }

    func cacheAppendedRows(
        _ summaries: [MacFSWEventRowSummary],
        previousCount: Int,
        newCount: Int
    ) -> Bool {
        let insertedCount = newCount - previousCount
        guard insertedCount > 0, !summaries.isEmpty else {
            return false
        }

        let cacheCount = min(insertedCount, summaries.count, maxDirectAppendCacheRows)
        let cacheStart = newCount - cacheCount
        let tailSummaries = summaries.suffix(cacheCount)
        for (offset, summary) in tailSummaries.enumerated() {
            rowCache[cacheStart + offset] = summary
        }

        markLoadedPagesIfComplete(overlapping: cacheStart..<newCount, visibleCount: newCount)
        evictRowPagesIfNeeded(visibleCount: newCount)
        rowCacheVersion += 1
        return true
    }

    func slideRowWindowCache(
        shiftedBy shiftCount: Int,
        appendedVisibleCount: Int,
        appendedSummaries: [MacFSWEventRowSummary],
        visibleCount: Int
    ) -> Bool {
        let shiftCount = min(max(0, shiftCount), visibleCount)
        let appendedVisibleCount = min(max(0, appendedVisibleCount), visibleCount)
        guard shiftCount > 0, appendedVisibleCount > 0, appendedSummaries.count >= appendedVisibleCount else {
            return false
        }

        queryGeneration += 1
        cancelRowLoads()

        let appendedStart = visibleCount - appendedVisibleCount
        var shiftedCache: [Int: MacFSWEventRowSummary] = [:]
        shiftedCache.reserveCapacity(min(rowCache.count + appendedVisibleCount, visibleCount))

        for (row, summary) in rowCache {
            let shiftedRow = row - shiftCount
            if shiftedRow >= 0, shiftedRow < appendedStart {
                shiftedCache[shiftedRow] = summary
            }
        }

        for (offset, summary) in appendedSummaries.suffix(appendedVisibleCount).enumerated() {
            shiftedCache[appendedStart + offset] = summary
        }

        rowCache = shiftedCache
        loadedRowPages.removeAll(keepingCapacity: true)
        rowPageAccessTicks.removeAll(keepingCapacity: true)
        if lastRequestedRowRange.lowerBound < lastRequestedRowRange.upperBound {
            let shiftedLower = max(0, lastRequestedRowRange.lowerBound - shiftCount)
            let shiftedUpper = max(shiftedLower, min(visibleCount, lastRequestedRowRange.upperBound - shiftCount))
            lastRequestedRowRange = shiftedLower..<shiftedUpper
        }
        rebuildLoadedPages(visibleCount: visibleCount)
        evictRowPagesIfNeeded(visibleCount: visibleCount)
        rowCacheVersion += 1
        rowCacheResetSerial += 1
        return true
    }

    func rebuildLoadedPages(visibleCount: Int) {
        let pages = Set(rowCache.keys.map { $0 / rowPageSize })
        for page in pages {
            let lowerBound = page * rowPageSize
            let upperBound = min(visibleCount, lowerBound + rowPageSize)
            guard lowerBound < upperBound else {
                continue
            }
            let isComplete = (lowerBound..<upperBound).allSatisfy { rowCache[$0] != nil }
            if isComplete {
                loadedRowPages.insert(page)
                markRowPageAccess(page)
            }
        }
    }

    func markLoadedPagesIfComplete(overlapping range: Range<Int>, visibleCount: Int) {
        guard range.lowerBound < range.upperBound else {
            return
        }
        let firstPage = range.lowerBound / rowPageSize
        let lastPage = (range.upperBound - 1) / rowPageSize
        for page in firstPage...lastPage {
            let lowerBound = page * rowPageSize
            let upperBound = min(visibleCount, lowerBound + rowPageSize)
            guard lowerBound < upperBound else {
                continue
            }
            let isComplete = (lowerBound..<upperBound).allSatisfy { rowCache[$0] != nil }
            if isComplete {
                loadedRowPages.insert(page)
                markRowPageAccess(page)
            }
        }
    }

    func invalidateRowPages(for range: Range<Int>) {
        guard range.lowerBound < range.upperBound else {
            return
        }
        let firstPage = range.lowerBound / rowPageSize
        let lastPage = (range.upperBound - 1) / rowPageSize
        for page in firstPage...lastPage {
            rowLoadTasks[page]?.cancel()
            rowLoadTasks[page] = nil
            inFlightRowPages.remove(page)
            loadedRowPages.remove(page)
            rowPageAccessTicks[page] = nil
            let lowerBound = page * rowPageSize
            let upperBound = min(visibleEventCount, lowerBound + rowPageSize)
            guard lowerBound < upperBound else {
                continue
            }
            for row in lowerBound..<upperBound {
                rowCache[row] = nil
            }
        }
        rowCacheVersion += 1
    }

    func cancelRowLoads() {
        for task in rowLoadTasks.values {
            task.cancel()
        }
        rowLoadTasks.removeAll(keepingCapacity: true)
        inFlightRowPages.removeAll(keepingCapacity: true)
    }

    func loadPages(for range: Range<Int>) {
        let firstPage = range.lowerBound / rowPageSize
        let lastPage = (range.upperBound - 1) / rowPageSize
        for page in firstPage...lastPage {
            markRowPageAccess(page)
            guard !loadedRowPages.contains(page), !inFlightRowPages.contains(page) else {
                continue
            }
            loadPage(page)
        }
    }

    func loadPage(_ page: Int) {
        inFlightRowPages.insert(page)
        let lowerBound = page * rowPageSize
        let upperBound = min(visibleEventCount, lowerBound + rowPageSize)
        guard lowerBound < upperBound else {
            inFlightRowPages.remove(page)
            return
        }

        let range = lowerBound..<upperBound
        let store = eventStore
        guard let snapshot = activeSnapshot else {
            inFlightRowPages.remove(page)
            return
        }
        let generation = queryGeneration
        rowLoadTasks[page] = Task { [weak self] in
            do {
                let rows = try await store.rowSummaries(
                    in: snapshot,
                    visibleRange: range
                )
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.inFlightRowPages.remove(page)
                    self.rowLoadTasks[page] = nil
                    for (offset, row) in rows.enumerated() {
                        self.rowCache[range.lowerBound + offset] = row
                    }
                    self.loadedRowPages.insert(page)
                    self.markRowPageAccess(page)
                    self.promoteSelectedRowIfLoaded(in: range)
                    self.evictRowPagesIfNeeded()
                    self.rowCacheVersion += 1
                    self.lastUpdatedAt = Date()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.inFlightRowPages.remove(page)
                    self.rowLoadTasks[page] = nil
                    self.reportError(error)
                }
            }
        }
    }

    func markRowPageAccess(_ page: Int) {
        rowPageAccessTick += 1
        rowPageAccessTicks[page] = rowPageAccessTick
    }

    func evictRowPagesIfNeeded(visibleCount: Int? = nil) {
        guard loadedRowPages.count > maxCachedRowPages else {
            return
        }

        let visibleCount = visibleCount ?? self.visibleEventCount
        let protectedPages = protectedRowPages(visibleCount: visibleCount)
        let candidates = loadedRowPages
            .filter { !protectedPages.contains($0) }
            .sorted { (rowPageAccessTicks[$0] ?? 0) < (rowPageAccessTicks[$1] ?? 0) }
        let excess = loadedRowPages.count - maxCachedRowPages
        for page in candidates.prefix(excess) {
            loadedRowPages.remove(page)
            rowPageAccessTicks[page] = nil
            let lowerBound = page * rowPageSize
            let upperBound = min(visibleCount, lowerBound + rowPageSize)
            guard lowerBound < upperBound else {
                continue
            }
            for row in lowerBound..<upperBound {
                rowCache[row] = nil
            }
        }
    }

    func protectedRowPages(visibleCount: Int? = nil) -> Set<Int> {
        let visibleCount = visibleCount ?? self.visibleEventCount
        var protected: Set<Int> = []
        func insertPages(for range: Range<Int>) {
            guard range.lowerBound < range.upperBound else {
                return
            }
            let lowerPage = max(0, range.lowerBound / rowPageSize)
            let upperPage = max(lowerPage, (range.upperBound - 1) / rowPageSize)
            for page in max(0, lowerPage - 1)...(upperPage + 1) {
                protected.insert(page)
            }
        }
        insertPages(for: lastRequestedRowRange)
        if followMode == .live, visibleCount > 0 {
            insertPages(for: max(0, visibleCount - rowPageSize)..<visibleCount)
        }
        return protected
    }
}
