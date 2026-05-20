import AppKit
import Combine
import Darwin
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import UniformTypeIdentifiers

extension MacFSWAppCoordinator {
    func refreshFilteredEvents(
        using queryOverride: MacFSWEventQuery?,
        allowAutoSelection: Bool = false
    ) async {
        let parsedQuery = queryOverride ?? MacFSWQueryParser.parse(queryText)
        let query = queryWithSelectedProcessFilter(parsedQuery)
        filterTask?.cancel()
        let generation = beginFilterRefresh()
        let store = eventStore
        let selectedEventIDAtStart = selectedEventID
        let followModeAtStart = followMode
        let requestedRangeAtStart = lastRequestedRowRange
        let pageSize = rowPageSize
        let oldSnapshot = activeSnapshot
        let task = Task { [weak self] in
            do {
                let snapshot = try await store.createResultSnapshot(matching: query, sortOrder: .oldestFirst)
                guard !Task.isCancelled else {
                    return
                }
                let count = snapshot.visibleCount

                let existingSelectionRow: Int?
                if let selectedEventIDAtStart {
                    existingSelectionRow = try await store.visibleRowIndex(
                        of: selectedEventIDAtStart,
                        in: snapshot
                    )
                } else {
                    existingSelectionRow = nil
                }
                guard !Task.isCancelled else {
                    return
                }

                let selectedRowForRefresh = existingSelectionRow ?? (allowAutoSelection && count > 0 ? count - 1 : nil)
                let initialRange: Range<Int>
                if count <= 0 {
                    initialRange = 0..<0
                } else if let selectedRowForRefresh {
                    let lower = max(0, min(selectedRowForRefresh, count - 1) - pageSize + 1)
                    let upper = min(count, lower + pageSize)
                    initialRange = lower..<upper
                } else if followModeAtStart == .live {
                    initialRange = max(0, count - pageSize)..<count
                } else if requestedRangeAtStart.lowerBound < requestedRangeAtStart.upperBound {
                    let lower = max(0, min(count - 1, requestedRangeAtStart.lowerBound))
                    let upper = min(count, max(lower + 1, min(count, requestedRangeAtStart.upperBound)))
                    initialRange = lower..<min(count, max(upper, min(count, lower + pageSize)))
                } else {
                    initialRange = 0..<min(count, pageSize)
                }

                let rows = try await store.rowSummaries(
                    in: snapshot,
                    visibleRange: initialRange
                )
                guard !Task.isCancelled else {
                    return
                }

                let selection: (id: UUID, row: Int)?
                if let existingSelectionRow, let selectedEventIDAtStart {
                    selection = (selectedEventIDAtStart, existingSelectionRow)
                } else if let selectedRowForRefresh {
                    let offset = selectedRowForRefresh - initialRange.lowerBound
                    if rows.indices.contains(offset) {
                        selection = (rows[offset].id, selectedRowForRefresh)
                    } else {
                        selection = nil
                    }
                } else {
                    selection = nil
                }

                let selectedEvent: MacFSWFileEvent?
                if let selection {
                    selectedEvent = try await store.event(id: selection.id)
                } else {
                    selectedEvent = nil
                }
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.commitFilterRefresh(
                        query: query,
                        snapshot: snapshot,
                        initialRange: initialRange,
                        rows: rows,
                        operationSummaries: [],
                        selection: selection,
                        selectedEvent: selectedEvent
                    )
                    self.refreshOperationSummaries(for: query, generation: generation)
                    if let oldSnapshot, oldSnapshot.id != snapshot.id {
                        self.retireSnapshot(oldSnapshot)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.isApplyingFilter = false
                    self.selectedEventIsLoading = false
                    self.reportError(error)
                }
            }
        }
        filterTask = task
        await task.value
    }

    func beginFilterRefresh() -> Int {
        queryGeneration += 1
        operationSummaryTask?.cancel()
        operationSummaryTask = nil
        cancelSelectedEventLoad()
        cancelRowLoads()
        pendingVisibleMatchCount = 0
        pendingVisibleRowSummaries.removeAll(keepingCapacity: true)
        isApplyingFilter = true
        selectedEventIsLoading = false
        return queryGeneration
    }

    func commitFilterRefresh(
        query: MacFSWEventQuery,
        snapshot: MacFSWEventResultSnapshot,
        initialRange: Range<Int>,
        rows: [MacFSWEventRowSummary],
        operationSummaries: [MacFSWOperationEventSummary],
        selection: (id: UUID, row: Int)?,
        selectedEvent: MacFSWFileEvent?
    ) {
        filterTask = nil
        activeQuery = query
        activeSnapshot = snapshot
        totalMatchingEventCount = snapshot.totalCount
        self.visibleEventCount = snapshot.visibleCount
        self.operationSummaries = self.operationSummaries(from: operationSummaries)

        rowCache.removeAll(keepingCapacity: true)
        loadedRowPages.removeAll(keepingCapacity: true)
        inFlightRowPages.removeAll(keepingCapacity: true)
        rowPageAccessTicks.removeAll(keepingCapacity: true)
        lastRequestedRowRange = initialRange
        for (offset, row) in rows.enumerated() {
            rowCache[initialRange.lowerBound + offset] = row
        }
        rebuildLoadedPages(visibleCount: snapshot.visibleCount)
        evictRowPagesIfNeeded(visibleCount: snapshot.visibleCount)
        rowCacheVersion += 1
        rowCacheResetSerial += 1
        tableResetSerial += 1

        if selectedEventID != selection?.id {
            selectedEventID = selection?.id
            if selection == nil {
                selectionResetSerial += 1
            }
        }
        selectedRow = selection?.row
        self.selectedEvent = selectedEvent
        selectedEventIsLoading = false

        if followMode == .live {
            unseenEventCount = 0
            isViewingLiveEdge = true
        }
        isApplyingFilter = false
        lastUpdatedAt = Date()
        preloadRowsForCurrentViewport()
    }

    func refreshOperationSummaries(for query: MacFSWEventQuery, generation: Int) {
        operationSummaryTask?.cancel()
        let store = eventStore
        operationSummaryTask = Task { [weak self] in
            do {
                let summaries = try await store.operationSummaries(matching: query)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.operationSummaries = self.operationSummaries(from: summaries)
                    self.operationSummaryTask = nil
                    self.lastUpdatedAt = Date()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.queryGeneration == generation else {
                        return
                    }
                    self.operationSummaryTask = nil
                    self.reportError(error)
                }
            }
        }
    }

    func retireSnapshot(_ snapshot: MacFSWEventResultSnapshot) {
        retiredSnapshotIDs.insert(snapshot.id)
        scheduleSnapshotCleanup()
    }

    func scheduleSnapshotCleanup() {
        snapshotCleanupTask?.cancel()
        snapshotCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            await self?.flushRetiredSnapshots()
        }
    }

    func flushRetiredSnapshots() async {
        let snapshotIDs = Array(retiredSnapshotIDs)
        retiredSnapshotIDs.removeAll(keepingCapacity: true)
        snapshotCleanupTask = nil
        guard !snapshotIDs.isEmpty else {
            return
        }

        do {
            try await eventStore.deleteResultSnapshots(snapshotIDs)
        } catch {
            reportError(error)
        }
    }

    func cancelSnapshotCleanup() {
        snapshotCleanupTask?.cancel()
        snapshotCleanupTask = nil
        retiredSnapshotIDs.removeAll(keepingCapacity: true)
    }

    func processSummary(for id: MacFSWProcessSummary.ID) -> MacFSWProcessSummary? {
        processSidebarStore.summary(for: id)
    }

    func queryWithSelectedProcessFilter(_ baseQuery: MacFSWEventQuery) -> MacFSWEventQuery {
        guard let selectedProcessID,
              let summary = processSummary(for: selectedProcessID) else {
            return baseQuery
        }

        var query = baseQuery
        query.processIdentity = summary.filterIdentity
        return query
    }

    func pauseLiveView() {
        guard followMode == .live else {
            return
        }
        invalidateLiveRender()
        followMode = .paused
    }

    func prepareEventSelection(row: Int) {
        guard row >= 0, row < visibleEventCount else {
            return
        }
        pauseLiveView()
    }

    func invalidateLiveRender() {
        liveRenderGeneration += 1
        renderTask?.cancel()
        renderTask = nil
    }

    func selectEvent(_ eventID: UUID?, row: Int? = nil) {
        selectedRow = row
        if row != nil || eventID != nil {
            pauseLiveView()
        }
        guard let eventID else {
            selectedEventID = nil
            if let row, row >= 0, row < visibleEventCount {
                selectedEventIsLoading = true
                requestRows(row..<min(row + 1, visibleEventCount))
                loadSelectedEvent(
                    atVisibleRow: row,
                    generation: queryGeneration
                )
            } else {
                cancelSelectedEventLoad()
                selectedEvent = nil
                selectedEventIsLoading = false
            }
            return
        }
        if selectedEventID == eventID, selectedEvent?.id == eventID {
            selectedEventIsLoading = false
            return
        }
        selectedEventID = eventID
        loadSelectedEvent(
            eventID,
            generation: queryGeneration
        )
    }

    func clearEventSelection() {
        cancelSelectedEventLoad()
        selectedEventID = nil
        selectedRow = nil
        selectedEvent = nil
        selectedEventIsLoading = false
        selectionResetSerial += 1
    }

    func nextSelectedEventLoadGeneration() -> Int {
        selectedEventLoadTask?.cancel()
        selectedEventLoadTask = nil
        selectedEventLoadGeneration += 1
        return selectedEventLoadGeneration
    }

    func cancelSelectedEventLoad() {
        selectedEventLoadTask?.cancel()
        selectedEventLoadTask = nil
        selectedEventLoadGeneration += 1
    }

    func loadSelectedEvent(_ eventID: UUID, generation: Int) {
        let loadGeneration = nextSelectedEventLoadGeneration()
        selectedEventIsLoading = true
        let store = eventStore
        selectedEventLoadTask = Task { [weak self] in
            do {
                guard !Task.isCancelled else {
                    return
                }
                let event = try await store.event(id: eventID)
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self,
                          self.queryGeneration == generation,
                          self.selectedEventLoadGeneration == loadGeneration,
                          self.selectedEventID == eventID else {
                        return
                    }
                    self.selectedEvent = event
                    self.selectedEventIsLoading = false
                    self.selectedEventLoadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self, self.selectedEventLoadGeneration == loadGeneration else {
                        return
                    }
                    self.selectedEventIsLoading = false
                    self.selectedEventLoadTask = nil
                    self.reportError(error)
                }
            }
        }
    }

    func loadSelectedEvent(atVisibleRow row: Int, generation: Int) {
        let store = eventStore
        guard let snapshot = activeSnapshot else {
            cancelSelectedEventLoad()
            selectedEventIsLoading = false
            return
        }
        let loadGeneration = nextSelectedEventLoadGeneration()
        selectedEventLoadTask = Task { [weak self] in
            do {
                guard !Task.isCancelled else {
                    return
                }
                let event = try await store.event(
                    in: snapshot,
                    visibleRow: row
                )
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    guard let self,
                          self.queryGeneration == generation,
                          self.selectedEventLoadGeneration == loadGeneration,
                          self.selectedRow == row else {
                        return
                    }
                    self.selectedEvent = event
                    self.selectedEventID = event?.id
                    self.selectedEventIsLoading = false
                    self.selectedEventLoadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.queryGeneration == generation,
                          self.selectedEventLoadGeneration == loadGeneration,
                          self.selectedRow == row else {
                        return
                    }
                    self.selectedEventIsLoading = false
                    self.selectedEventLoadTask = nil
                    self.reportError(error)
                }
            }
        }
    }

    func promoteSelectedRowIfLoaded(in range: Range<Int>) {
        guard let selectedRow, range.contains(selectedRow), let summary = rowCache[selectedRow] else {
            return
        }
        if selectedEventID != summary.id {
            selectedEventID = summary.id
            loadSelectedEvent(summary.id, generation: queryGeneration)
        }
    }
}
