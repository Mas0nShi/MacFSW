import Darwin
import Foundation
import MacFSWCore

enum ProcessSummaryReducer {
    static func update(
        index: inout [MacFSWProcessSummary.ID: MacFSWProcessSummary],
        with events: [MacFSWFileEvent]
    ) {
        for event in events {
            let id = MacFSWProcessSummary.id(for: event)
            var summary = index[id] ?? MacFSWProcessSummary(event: event, eventCount: 0)
            summary.processName = event.process.processName
            summary.pid = event.process.pid
            summary.auditToken = event.process.auditToken
            summary.executablePath = event.process.executablePath
            summary.signingSummary = event.process.signingID ?? event.process.teamID ?? "-"
            summary.uid = event.uid
            summary.gid = event.gid
            summary.eventCount += 1
            summary.lastEventNS = max(summary.lastEventNS, event.timestampNS)
            summary.isPlatformBinary = event.process.isPlatformBinary
            let identityKey = event.process.auditToken.isEmpty
                ? "exec:\(event.process.executablePath)"
                : "audit:\(event.process.auditToken)"
            if summary.auditToken != event.process.auditToken || summary.executablePath != event.process.executablePath {
                summary.identityCount = max(summary.identityCount, 2)
            } else if !identityKey.isEmpty {
                summary.identityCount = max(summary.identityCount, 1)
            }
            index[id] = summary
        }
    }

    static func summaries(from index: [MacFSWProcessSummary.ID: MacFSWProcessSummary]) -> [MacFSWProcessSummary] {
        index.values
            .map { summary in
                var summary = summary
                summary.lifecycle = lifecycle(for: summary.pid)
                return summary
            }
            .sortedForDisplay()
    }

    static func groups(from summaries: [MacFSWProcessSummary]) -> [MacFSWProcessGroupSummary] {
        Dictionary(grouping: summaries, by: \.processName)
            .map { processName, summaries in
                MacFSWProcessGroupSummary(
                    processName: processName,
                    summaries: summaries.sortedForDisplay(),
                    eventCount: summaries.reduce(0) { $0 + $1.eventCount },
                    lastEventNS: summaries.map(\.lastEventNS).max() ?? 0,
                    exitedCount: summaries.filter { $0.lifecycle == .exited }.count
                )
            }
            .sorted { lhs, rhs in
                if lhs.eventCount != rhs.eventCount {
                    return lhs.eventCount > rhs.eventCount
                }
                if lhs.lastEventNS != rhs.lastEventNS {
                    return lhs.lastEventNS > rhs.lastEventNS
                }
                return lhs.processName.localizedCaseInsensitiveCompare(rhs.processName) == .orderedAscending
            }
    }

    static func filteredSummaries(
        _ summaries: [MacFSWProcessSummary],
        query rawQuery: String,
        includeExited: Bool
    ) -> [MacFSWProcessSummary] {
        let summaries = includeExited
            ? summaries
            : summaries.filter { $0.lifecycle != .exited }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return summaries
        }
        return summaries.filter { summary in
            let values = [
                summary.displayName,
                summary.processName,
                "\(summary.pid)",
                summary.executablePath,
                summary.signingSummary,
            ]
            if query.contains("*") || query.contains("?") {
                return values.contains { WildcardMatcher.matches(query, value: $0) }
            }
            return values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    static func lifecycle(for pid: Int32) -> MacFSWProcessLifecycle {
        guard pid > 0 else {
            return .unknown
        }
        errno = 0
        if kill(pid_t(pid), 0) == 0 || errno == EPERM {
            return .running
        }
        if errno == ESRCH {
            return .exited
        }
        return .unknown
    }
}
