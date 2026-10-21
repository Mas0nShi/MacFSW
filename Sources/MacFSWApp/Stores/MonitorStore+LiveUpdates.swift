import Foundation
import MacFSWCore

extension MonitorStore {
    func jumpToLive() {
        invalidateLiveRender()
        let visibleMutationCount = pendingVisibleMatchCount
        let visibleRowSummaries = pendingVisibleRowSummaries
        pendingVisibleMatchCount = 0
        pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
        followMode = .live
        unseenEventCount = 0
        isViewingLiveEdge = true
        cancelSelectedEventLoad()
        selectedEventID = nil
        selectedRow = nil
        selectedEvent = nil
        selectedEventIsLoading = false
        selectionResetSerial += 1
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.activeSnapshot == nil {
                await self.refreshFilteredEvents()
            } else if visibleMutationCount > 0 {
                await self.refreshVisibleRowsAfterStoreChange(
                    visibleMutationCount: visibleMutationCount,
                    appendedSummaries: visibleRowSummaries,
                    renderGeneration: self.liveRenderGeneration
                )
            } else {
                self.preloadRowsForCurrentViewport()
                self.lastUpdatedAt = Date()
            }
            self.scrollToLiveSerial += 1
        }
    }

    /// Folds newly captured events into the live view: counts the ones the
    /// active query shows and schedules a throttled render.
    func ingest(_ events: [MacFSWFileEvent]) {
        let visibleEvents = events.filter { activeQuery.matches($0) }
        pendingVisibleMatchCount += visibleEvents.count
        pendingVisibleRowSummaries.append(contentsOf: visibleEvents.map(MacFSWEventRowSummary.init(event:)))
        if followMode != .live {
            unseenEventCount += visibleEvents.count
        }
        scheduleRenderRefresh()
    }

    func scheduleRenderRefresh(immediate: Bool = false) {
        if immediate {
            renderTask?.cancel()
            renderTask = nil
        }
        guard renderTask == nil else {
            return
        }

        renderTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.applyScheduledRender()
        }
    }

    func applyScheduledRender() async {
        defer {
            renderTask = nil
            if !Task.isCancelled, followMode == .live, pendingVisibleMatchCount > 0 {
                scheduleRenderRefresh(immediate: true)
            }
        }

        guard !isApplyingFilter else {
            pendingVisibleMatchCount = 0
            pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
            lastUpdatedAt = Date()
            return
        }

        guard followMode == .live else {
            lastUpdatedAt = Date()
            return
        }

        let visibleMutationCount = pendingVisibleMatchCount
        let visibleRowSummaries = pendingVisibleRowSummaries
        pendingVisibleMatchCount = 0
        pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
        guard visibleMutationCount > 0 else {
            lastUpdatedAt = Date()
            return
        }

        await refreshVisibleRowsAfterStoreChange(
            visibleMutationCount: visibleMutationCount,
            appendedSummaries: visibleRowSummaries,
            renderGeneration: liveRenderGeneration
        )
    }

    func refreshVisibleRowsAfterStoreChange(
        visibleMutationCount: Int,
        appendedSummaries: [MacFSWEventRowSummary],
        renderGeneration: Int
    ) async {
        do {
            guard followMode == .live, liveRenderGeneration == renderGeneration else {
                requeueVisibleRender(
                    visibleMutationCount: visibleMutationCount,
                    appendedSummaries: appendedSummaries
                )
                return
            }
            guard let snapshot = activeSnapshot else {
                await refreshFilteredEvents()
                return
            }
            let updatedSnapshot = try await eventStore.appendRowsToResultSnapshot(
                snapshot,
                rows: appendedSummaries,
                limit: activeQuery.limit
            )
            guard followMode == .live, liveRenderGeneration == renderGeneration else {
                retireSnapshot(updatedSnapshot)
                requeueVisibleRender(
                    visibleMutationCount: visibleMutationCount,
                    appendedSummaries: appendedSummaries
                )
                return
            }
            // The monitor never applies a row limit, so live events only
            // ever extend the result at its tail.
            activeSnapshot = updatedSnapshot
            applyOperationSummaryDelta(from: appendedSummaries)
            let previousCount = visibleEventCount
            let count = updatedSnapshot.visibleCount
            let didCacheAppendedRows = cacheAppendedRows(
                appendedSummaries,
                previousCount: previousCount,
                newCount: count
            )
            visibleEventCount = count
            totalMatchingEventCount = updatedSnapshot.totalCount
            if count > previousCount, !didCacheAppendedRows {
                invalidateRowPages(for: previousCount..<count)
            }

            if followMode == .live, isViewingLiveEdge {
                unseenEventCount = 0
            }
            preloadRowsForCurrentViewport()
            lastUpdatedAt = Date()
        } catch {
            reportError(error)
        }
    }

    func requeueVisibleRender(
        visibleMutationCount: Int,
        appendedSummaries: [MacFSWEventRowSummary]
    ) {
        guard visibleMutationCount > 0 else {
            lastUpdatedAt = Date()
            return
        }
        pendingVisibleMatchCount += visibleMutationCount
        if !appendedSummaries.isEmpty {
            pendingVisibleRowSummaries.insert(contentsOf: appendedSummaries, at: 0)
        }
        if followMode != .live {
            unseenEventCount += visibleMutationCount
        }
        lastUpdatedAt = Date()
    }
}
