import MacFSWCore

extension MacFSWProcessSummary {
    static func id(for event: MacFSWFileEvent) -> String {
        event.process.filterIdentity.stableID
    }

    init(event: MacFSWFileEvent, eventCount: Int) {
        self.init(
            id: Self.id(for: event),
            processName: event.process.processName,
            pid: event.process.pid,
            auditToken: event.process.auditToken,
            executablePath: event.process.executablePath,
            signingSummary: event.process.signingID ?? event.process.teamID ?? "-",
            uid: event.uid,
            gid: event.gid,
            eventCount: eventCount,
            lastEventNS: event.timestampNS,
            isPlatformBinary: event.process.isPlatformBinary,
            identityCount: 1
        )
    }
}

extension Collection where Element == MacFSWProcessSummary {
    func sortedForDisplay() -> [MacFSWProcessSummary] {
        sorted { lhs, rhs in
            if lhs.eventCount != rhs.eventCount {
                return lhs.eventCount > rhs.eventCount
            }
            if lhs.lastEventNS != rhs.lastEventNS {
                return lhs.lastEventNS > rhs.lastEventNS
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}

