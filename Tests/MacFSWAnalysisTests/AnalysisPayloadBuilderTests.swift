import Foundation
import MacFSWCore
import XCTest

@testable import MacFSWAnalysis

final class AnalysisPayloadBuilderTests: XCTestCase {
    private static let context = MacFSWAnalysisProcessContext(
        displayName: "chmod(700)",
        processName: "chmod",
        pid: 700,
        executablePath: "/usr/bin/chmod",
        signingSummary: "com.example.chmod",
        uid: 501,
        gid: 20,
        eventCount: 10,
        isPlatformBinary: false,
        lifecycle: "Exited"
    )

    private func makeEvents(sequences: [UInt64]) -> [MacFSWFileEvent] {
        let process = MacFSWProcessIdentity(
            pid: 700,
            auditToken: "payload",
            executablePath: "/usr/bin/chmod",
            processName: "chmod"
        )
        return sequences.map { seq in
            MacFSWFileEvent(
                sequence: seq,
                eventType: .write,
                process: process,
                targetPath: "/tmp/\(seq)"
            )
        }
    }

    func testFillsNewestFirstWithinBudgetAndPresentsChronologically() {
        let events = makeEvents(sequences: Array(1...20))
        // Rough per-line cost with these paths is ~180 chars. 400 chars is
        // enough for exactly 2 event lines under any reasonable formatting.
        let prepared = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: events,
            totalEventCount: 100,
            eventSampleCharacterBudget: 400
        )

        XCTAssertEqual(prepared.fetchedEventCount, 20)
        XCTAssertGreaterThanOrEqual(prepared.sampledEventCount, 1)
        XCTAssertLessThan(prepared.sampledEventCount, 20, "budget must trim the sample block")

        // Newest-first fill: seq=20 must appear; older-than-cutoff seqs must not.
        XCTAssertTrue(prepared.userPrompt.contains("seq=20"))
        // Chronological presentation: within the sampled block, lower seqs
        // print before higher ones.
        let older = prepared.userPrompt.range(of: "seq=\(20 - prepared.sampledEventCount + 1)")!
        let newest = prepared.userPrompt.range(of: "seq=20")!
        XCTAssertLessThan(older.lowerBound, newest.lowerBound)
    }

    func testCoverageLineDescribesSamplingHonestly() {
        let full = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: makeEvents(sequences: [1, 2, 3]),
            totalEventCount: 3
        )
        XCTAssertTrue(full.userPrompt.contains("Showing all 3 events in the session."))

        let partial = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: makeEvents(sequences: Array(1...10)),
            totalEventCount: 100,
            eventSampleCharacterBudget: 400
        )
        XCTAssertTrue(
            partial.userPrompt.contains("most recent of 10 fetched events (100 total in session)"),
            "coverage line must state sampled/fetched/total"
        )
    }

    func testTinyBudgetIncludesAtLeastTheNewestEvent() {
        let prepared = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: makeEvents(sequences: [1, 2, 3, 4, 5]),
            totalEventCount: 5,
            eventSampleCharacterBudget: 1
        )
        XCTAssertEqual(prepared.sampledEventCount, 1)
        XCTAssertTrue(prepared.userPrompt.contains("seq=5"))
        XCTAssertFalse(prepared.userPrompt.contains("seq=4"))
    }

    func testZeroEventsRendersEmptyMessage() {
        let prepared = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: [],
            totalEventCount: 0
        )
        XCTAssertEqual(prepared.fetchedEventCount, 0)
        XCTAssertEqual(prepared.sampledEventCount, 0)
        XCTAssertTrue(prepared.userPrompt.contains("No event samples"))
        XCTAssertTrue(prepared.userPrompt.contains("No events were available for this process."))
    }

    func testLanguageBackstopAppendsOnlyWhenPlaceholderAbsentAndNonEnglish() {
        let templateWithoutPlaceholder = MacFSWAnalysisPromptTemplate(
            name: "Custom",
            summary: "no language placeholder",
            systemPromptTemplate: "You analyze events.",
            userPromptTemplate: "Events: {{event_samples}}"
        )
        let templateWithPlaceholder = MacFSWAnalysisPromptTemplate(
            name: "Custom",
            summary: "with language placeholder",
            systemPromptTemplate: "You analyze events. Respond in {{output_language}}.",
            userPromptTemplate: "Events: {{event_samples}}"
        )

        let noPlaceholderJapanese = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: makeEvents(sequences: [1]),
            totalEventCount: 1,
            template: templateWithoutPlaceholder,
            outputLanguageName: "Japanese"
        )
        XCTAssertTrue(noPlaceholderJapanese.systemPrompt.contains("Write the entire report in Japanese."))

        let noPlaceholderEnglish = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: makeEvents(sequences: [1]),
            totalEventCount: 1,
            template: templateWithoutPlaceholder,
            outputLanguageName: "English"
        )
        XCTAssertFalse(
            noPlaceholderEnglish.systemPrompt.contains("Write the entire report"),
            "English is the default; no backstop needed"
        )

        let withPlaceholder = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: makeEvents(sequences: [1]),
            totalEventCount: 1,
            template: templateWithPlaceholder,
            outputLanguageName: "Japanese"
        )
        XCTAssertTrue(withPlaceholder.systemPrompt.contains("Respond in Japanese."))
        XCTAssertFalse(
            withPlaceholder.systemPrompt.contains("Write the entire report in Japanese."),
            "the placeholder already carried the setting; no double injection"
        )
    }

    func testSampledCountIsZeroWhenTemplateOmitsSamplesPlaceholder() {
        let template = MacFSWAnalysisPromptTemplate(
            name: "Aggregate Only",
            summary: "no samples",
            systemPromptTemplate: "You analyze events.",
            userPromptTemplate: "Ops: {{operation_distribution}}"
        )
        let prepared = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: makeEvents(sequences: [1, 2, 3]),
            totalEventCount: 3,
            template: template
        )
        XCTAssertEqual(prepared.fetchedEventCount, 3)
        XCTAssertEqual(prepared.sampledEventCount, 0, "stat must reflect what the model actually saw")
    }

    func testProcessContextBlockCarriesCoverageCounts() {
        let prepared = MacFSWAnalysisPayloadBuilder.build(
            process: Self.context,
            events: makeEvents(sequences: Array(1...5)),
            totalEventCount: 100
        )
        XCTAssertTrue(prepared.userPrompt.contains("Total events in session: 100"))
        XCTAssertTrue(prepared.userPrompt.contains("Events fetched: 5"))
        XCTAssertTrue(prepared.userPrompt.contains("Events sampled below: 5"))
    }
}
