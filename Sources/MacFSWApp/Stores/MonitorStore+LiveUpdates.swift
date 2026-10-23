import Foundation
import MacFSWCore

extension MonitorStore {
    /// Drops the selection and follows the newest events again.
    func jumpToLive() {
        cancelSelectedEventLoad()
        selectedEventID = nil
        selectedRow = nil
        selectedEvent = nil
        selectedEventIsLoading = false
        selectionResetSerial += 1
        resumeFollowing()
        preloadRowsForCurrentViewport()
        scrollToLiveSerial += 1
    }

    /// Stops scrolling to new events. Rows keep arriving below; appending
    /// at the tail never moves what the user is looking at.
    func pauseFollowing() {
        followMode = .paused
    }

    func resumeFollowing() {
        followMode = .live
        unseenEventCount = 0
    }

    /// The table reports the user scrolling away from, or back to, the newest row.
    func userChangedFollowing(_ following: Bool) {
        following ? resumeFollowing() : pauseFollowing()
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
            if !Task.isCancelled, pendingVisibleMatchCount > 0 {
                scheduleRenderRefresh(immediate: true)
            }
        }

        guard !isApplyingFilter else {
            pendingVisibleMatchCount = 0
            pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
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
        guard liveRenderGeneration == renderGeneration else {
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
        let updatedSnapshot = await eventStore.appendRowsToResultSnapshot(
            snapshot,
            rows: appendedSummaries,
            limit: activeQuery.limit
        )
        guard liveRenderGeneration == renderGeneration else {
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
        preloadRowsForCurrentViewport()
        lastUpdatedAt = Date()
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
        lastUpdatedAt = Date()
    }
}
