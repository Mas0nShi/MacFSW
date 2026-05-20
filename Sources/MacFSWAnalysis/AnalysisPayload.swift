import Foundation
import MacFSWCore

public struct MacFSWAnalysisProcessContext: Equatable, Sendable {
    public var displayName: String
    public var processName: String
    public var pid: Int32
    public var executablePath: String
    public var signingSummary: String
    public var uid: UInt32
    public var gid: UInt32
    public var eventCount: Int
    public var isPlatformBinary: Bool
    public var lifecycle: String

    public init(
        displayName: String,
        processName: String,
        pid: Int32,
        executablePath: String,
        signingSummary: String,
        uid: UInt32,
        gid: UInt32,
        eventCount: Int,
        isPlatformBinary: Bool,
        lifecycle: String
    ) {
        self.displayName = displayName
        self.processName = processName
        self.pid = pid
        self.executablePath = executablePath
        self.signingSummary = signingSummary
        self.uid = uid
        self.gid = gid
        self.eventCount = eventCount
        self.isPlatformBinary = isPlatformBinary
        self.lifecycle = lifecycle
    }
}

public struct MacFSWAnalysisPreparedRequest: Sendable {
    public var systemPrompt: String
    public var userPrompt: String
    public var eventCount: Int
    public var payloadEventCount: Int
    public var pathCount: Int
    public var operationCount: Int
    public var operationDistribution: [(String, Int)]

    public init(
        systemPrompt: String,
        userPrompt: String,
        eventCount: Int,
        payloadEventCount: Int,
        pathCount: Int,
        operationCount: Int,
        operationDistribution: [(String, Int)]
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.eventCount = eventCount
        self.payloadEventCount = payloadEventCount
        self.pathCount = pathCount
        self.operationCount = operationCount
        self.operationDistribution = operationDistribution
    }
}

public enum MacFSWAnalysisPayloadBuilder {
    public static func build(
        process: MacFSWAnalysisProcessContext,
        events: [MacFSWFileEvent],
        totalEventCount: Int,
        maxEventSamples: Int = 80
    ) -> MacFSWAnalysisPreparedRequest {
        let orderedEvents = events.sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence {
                return lhs.sequence < rhs.sequence
            }
            return lhs.timestampNS < rhs.timestampNS
        }
        let paths = Set(orderedEvents.flatMap { event in
            [event.targetPath, event.sourcePath].compactMap { $0 }
        })
        let operationCounts = Dictionary(grouping: orderedEvents, by: { $0.eventType.rawValue })
            .mapValues(\.count)
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key < rhs.key
            }
        let topPaths = Dictionary(grouping: orderedEvents.flatMap { event in
            [event.targetPath, event.sourcePath].compactMap { $0 }
        }, by: { $0 })
            .mapValues(\.count)
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key < rhs.key
            }
            .prefix(24)
        let samples = orderedEvents.suffix(max(0, maxEventSamples))

        let systemPrompt = """
        You are analyzing macOS Endpoint Security file-system event logs for a security researcher.
        Produce a concise Markdown report grounded only in the supplied event data.
        Do not invent facts, severity scores, permissions, entitlement state, or user intent.
        Prefer concrete supporting details: operation names, paths, process identity, uid/gid, signing, raw event type, and captured operation parameters.
        Call out uncertainty explicitly when the log does not contain enough data.
        """

        var lines: [String] = []
        lines.append("# Process File-System Event Analysis")
        lines.append("")
        lines.append("## Process")
        lines.append("- Display: \(process.displayName)")
        lines.append("- Name: \(process.processName)")
        lines.append("- PID: \(process.pid)")
        lines.append("- Lifecycle: \(process.lifecycle)")
        lines.append("- Executable: \(process.executablePath)")
        lines.append("- Signing: \(process.signingSummary.isEmpty ? "-" : process.signingSummary)")
        lines.append("- UID/GID: \(process.uid)/\(process.gid)")
        lines.append("- Platform binary: \(process.isPlatformBinary ? "true" : "false")")
        lines.append("- Total events for process in session: \(totalEventCount)")
        lines.append("- Events included in this payload: \(orderedEvents.count)")
        lines.append("")
        lines.append("## Operation Distribution")
        if operationCounts.isEmpty {
            lines.append("- No events were available for this process.")
        } else {
            for (operation, count) in operationCounts {
                lines.append("- \(operation): \(count)")
            }
        }
        lines.append("")
        lines.append("## Top Paths")
        if topPaths.isEmpty {
            lines.append("- No paths were available.")
        } else {
            for (path, count) in topPaths {
                lines.append("- \(path): \(count)")
            }
        }
        lines.append("")
        lines.append("## Event Samples")
        if samples.isEmpty {
            lines.append("- No event samples.")
        } else {
            for event in samples {
                lines.append("- \(format(timestampNS: event.timestampNS)) seq=\(event.sequence) op=\(event.eventType.rawValue) class=\(event.operationClass.rawValue) target=\(event.targetPath)\(sourceSuffix(event))\(detailSuffix(event)) raw=\(rawEventDescription(event)) uid=\(event.uid) gid=\(event.gid)")
            }
        }
        lines.append("")
        lines.append("## Required Report Shape")
        lines.append("Return Markdown with these sections: Summary, Notable Behaviors, Supporting Events, Unknowns, Follow-up Checks.")

        return MacFSWAnalysisPreparedRequest(
            systemPrompt: systemPrompt,
            userPrompt: lines.joined(separator: "\n"),
            eventCount: totalEventCount,
            payloadEventCount: orderedEvents.count,
            pathCount: paths.count,
            operationCount: operationCounts.count,
            operationDistribution: operationCounts.map { ($0.key, $0.value) }
        )
    }

    private static func sourceSuffix(_ event: MacFSWFileEvent) -> String {
        guard let sourcePath = event.sourcePath, !sourcePath.isEmpty else {
            return ""
        }
        return " source=\(sourcePath)"
    }

    private static func detailSuffix(_ event: MacFSWFileEvent) -> String {
        let detail = event.operationDetailSummary
        guard !detail.isEmpty else {
            return ""
        }
        return " detail=\"\(detail)\""
    }

    private static func rawEventDescription(_ event: MacFSWFileEvent) -> String {
        guard let rawEventTypeValue = event.rawEventTypeValue else {
            return event.rawEventType
        }
        return "\(event.rawEventType)(\(rawEventTypeValue))"
    }

    private static func format(timestampNS: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampNS) / 1_000_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
