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
    /// Total events for this process across the session.
    public var totalEventCount: Int
    /// Events read from the store (bounded by settings.maxEvents).
    public var fetchedEventCount: Int
    /// Events actually rendered into the prompt (0 if the template omits
    /// the samples placeholder).
    public var sampledEventCount: Int
    public var pathCount: Int
    public var operationCount: Int
    public var operationDistribution: [(String, Int)]

    public init(
        systemPrompt: String,
        userPrompt: String,
        totalEventCount: Int,
        fetchedEventCount: Int,
        sampledEventCount: Int,
        pathCount: Int,
        operationCount: Int,
        operationDistribution: [(String, Int)]
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.totalEventCount = totalEventCount
        self.fetchedEventCount = fetchedEventCount
        self.sampledEventCount = sampledEventCount
        self.pathCount = pathCount
        self.operationCount = operationCount
        self.operationDistribution = operationDistribution
    }
}

public enum MacFSWAnalysisPayloadBuilder {
    /// Renders a prompt from a template + captured events. Sampling is
    /// budget-driven: event lines fill NEWEST-first up to
    /// `eventSampleCharacterBudget` (always at least one event when any are
    /// present), then the sample block is emitted in chronological order
    /// under a coverage statement that names sampled/fetched/total counts.
    /// Aggregate sections (operation distribution, top paths) always cover
    /// every fetched event so the model sees the shape of the omitted tail.
    public static func build(
        process: MacFSWAnalysisProcessContext,
        events: [MacFSWFileEvent],
        totalEventCount: Int,
        template: MacFSWAnalysisPromptTemplate = MacFSWAnalysisPromptTemplateCatalog.defaultTemplate,
        outputLanguageName: String = "English",
        eventSampleCharacterBudget: Int = 120_000
    ) -> MacFSWAnalysisPreparedRequest {
        let orderedEvents = events.sorted { lhs, rhs in
            if lhs.sequence != rhs.sequence {
                return lhs.sequence < rhs.sequence
            }
            return lhs.timestampNS < rhs.timestampNS
        }
        let fetchedCount = orderedEvents.count
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

        let sampledEvents = sampleEventsWithinBudget(
            orderedEvents,
            budget: eventSampleCharacterBudget
        )

        let processContextBlock = renderProcessContext(
            process: process,
            totalEventCount: totalEventCount,
            fetchedEventCount: fetchedCount,
            sampledEventCount: sampledEvents.count
        )
        let operationBlock = renderOperationDistribution(operationCounts)
        let topPathsBlock = renderTopPaths(Array(topPaths))
        let samplesBlock = renderEventSamples(
            sampledEvents,
            totalEventCount: totalEventCount,
            fetchedEventCount: fetchedCount
        )

        let substitutions: [String: String] = [
            "process_context": processContextBlock,
            "operation_distribution": operationBlock,
            "top_paths": topPathsBlock,
            "event_samples": samplesBlock,
            "total_event_count": String(totalEventCount),
            "fetched_event_count": String(fetchedCount),
            "sampled_event_count": String(sampledEvents.count),
            "process_name": process.displayName,
            "output_language": outputLanguageName,
        ]
        var systemPrompt = MacFSWPromptTemplateRenderer.render(
            template.systemPromptTemplate,
            substitutions: substitutions
        )
        let userPrompt = MacFSWPromptTemplateRenderer.render(
            template.userPromptTemplate,
            substitutions: substitutions
        )

        // Backstop: if the author's template ignores {{output_language}} we
        // still honor the setting so the language picker never appears inert.
        let combined = template.systemPromptTemplate + template.userPromptTemplate
        let placeholders = MacFSWPromptTemplateRenderer.placeholderNames(in: combined)
        if !placeholders.contains("output_language"),
           outputLanguageName.lowercased() != "english" {
            systemPrompt += "\n\nWrite the entire report in \(outputLanguageName)."
        }

        let sampledCount = placeholders.contains("event_samples") ? sampledEvents.count : 0

        return MacFSWAnalysisPreparedRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            totalEventCount: totalEventCount,
            fetchedEventCount: fetchedCount,
            sampledEventCount: sampledCount,
            pathCount: paths.count,
            operationCount: operationCounts.count,
            operationDistribution: operationCounts.map { ($0.key, $0.value) }
        )
    }

    // MARK: - Section rendering

    private static func renderProcessContext(
        process: MacFSWAnalysisProcessContext,
        totalEventCount: Int,
        fetchedEventCount: Int,
        sampledEventCount: Int
    ) -> String {
        [
            "- Display: \(process.displayName)",
            "- Name: \(process.processName)",
            "- PID: \(process.pid)",
            "- Lifecycle: \(process.lifecycle)",
            "- Executable: \(process.executablePath)",
            "- Signing: \(process.signingSummary.isEmpty ? "-" : process.signingSummary)",
            "- UID/GID: \(process.uid)/\(process.gid)",
            "- Platform binary: \(process.isPlatformBinary ? "true" : "false")",
            "- Total events in session: \(totalEventCount)",
            "- Events fetched: \(fetchedEventCount)",
            "- Events sampled below: \(sampledEventCount)",
        ].joined(separator: "\n")
    }

    private static func renderOperationDistribution(_ counts: [(key: String, value: Int)]) -> String {
        guard !counts.isEmpty else {
            return "- No events were available for this process."
        }
        return counts.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private static func renderTopPaths(_ topPaths: [(key: String, value: Int)]) -> String {
        guard !topPaths.isEmpty else {
            return "- No paths were available."
        }
        return topPaths.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
    }

    private static func renderEventSamples(
        _ events: [MacFSWFileEvent],
        totalEventCount: Int,
        fetchedEventCount: Int
    ) -> String {
        var lines: [String] = [coverageLine(
            sampledCount: events.count,
            fetchedCount: fetchedEventCount,
            totalCount: totalEventCount
        )]
        if events.isEmpty {
            lines.append("- No event samples.")
        } else {
            for event in events {
                lines.append(formatEventLine(event))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func coverageLine(sampledCount: Int, fetchedCount: Int, totalCount: Int) -> String {
        if sampledCount == 0 {
            return "No event samples are included (of \(fetchedCount) fetched, \(totalCount) total in session)."
        }
        if sampledCount == fetchedCount, fetchedCount == totalCount {
            return "Showing all \(totalCount) events in the session."
        }
        if sampledCount == fetchedCount {
            return "Showing all \(fetchedCount) fetched events (of \(totalCount) total in session)."
        }
        return "Showing the \(sampledCount) most recent of \(fetchedCount) fetched events (\(totalCount) total in session)."
    }

    // MARK: - Sampling

    private static func sampleEventsWithinBudget(
        _ orderedEvents: [MacFSWFileEvent],
        budget: Int
    ) -> [MacFSWFileEvent] {
        guard !orderedEvents.isEmpty else {
            return []
        }
        // Fill newest-first up to `budget`, always keeping at least one
        // event when any exist, then present chronologically.
        var included: [MacFSWFileEvent] = []
        var used = 0
        for event in orderedEvents.reversed() {
            let line = formatEventLine(event)
            let cost = line.count + 1 // for the trailing newline
            if !included.isEmpty, used + cost > budget {
                break
            }
            included.append(event)
            used += cost
        }
        included.reverse()
        return included
    }

    private static func formatEventLine(_ event: MacFSWFileEvent) -> String {
        "- \(format(timestampNS: event.timestampNS)) seq=\(event.sequence) op=\(event.eventType.rawValue) class=\(event.operationClass.rawValue) target=\(event.targetPath)\(sourceSuffix(event))\(detailSuffix(event)) raw=\(rawEventDescription(event)) uid=\(event.uid) gid=\(event.gid)"
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
