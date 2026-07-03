import MacFSWCore
import XCTest

@testable import MacFSWApp

final class QuerySuggestionEngineTests: XCTestCase {
    func testEmptyInputShowsHistoryThenFields() {
        var context = QuerySuggestionContext()
        context.history = ["op:rename path:/Library"]

        let suggestions = QuerySuggestionEngine.suggestions(for: "", context: context)

        XCTAssertEqual(suggestions.first?.kind, .history)
        XCTAssertEqual(suggestions.first?.resultText, "op:rename path:/Library")
        XCTAssertEqual(suggestions.dropFirst().first?.label, "op:")
        XCTAssertEqual(
            suggestions.count,
            1 + MacFSWQueryFieldCatalog.descriptors.count - 1,
            "history entry plus every field except .any — nothing truncated"
        )
        XCTAssertTrue(suggestions.dropFirst().allSatisfy { suggestion in
            if case .field = suggestion.kind {
                return true
            }
            return false
        })
    }

    func testBarePrefixRanksCanonicalPrefixFirst() {
        let suggestions = QuerySuggestionEngine.suggestions(for: "o", context: QuerySuggestionContext())

        XCTAssertEqual(suggestions.first?.label, "op:")
        XCTAssertEqual(suggestions.first?.resultText, "op:")
    }

    func testBarePositionAfterCompleteTermSuggestsFields() {
        let suggestions = QuerySuggestionEngine.suggestions(for: "op:rename ", context: QuerySuggestionContext())

        XCTAssertEqual(suggestions.first?.label, "op:")
        XCTAssertEqual(suggestions.first?.resultText, "op:rename op:")
    }

    func testFieldCompletionPreservesNegationAndParens() {
        let negated = QuerySuggestionEngine.suggestions(for: "-o", context: QuerySuggestionContext())
        XCTAssertEqual(negated.first?.resultText, "-op:")

        let parenthesized = QuerySuggestionEngine.suggestions(for: "(op:re", context: QuerySuggestionContext())
        XCTAssertEqual(parenthesized.first?.resultText, "(op:rename ")
    }

    func testEventTypeValuesListEveryCaseAndPrefixRank() {
        let all = QuerySuggestionEngine.suggestions(for: "op:", context: QuerySuggestionContext())
        XCTAssertEqual(all.count, MacFSWEventType.allCases.count, "every event type must be offered; the list scrolls")
        XCTAssertTrue(all.allSatisfy { $0.kind == .value })

        let prefixed = QuerySuggestionEngine.suggestions(for: "op:re", context: QuerySuggestionContext())
        XCTAssertEqual(prefixed.first?.label, "rename")
        XCTAssertEqual(prefixed.first?.resultText, "op:rename ")
        XCTAssertTrue(prefixed.contains { $0.label == "create" }, "contains-matches should still be offered")
    }

    func testCommaSeparatedValuesCompleteLastSegment() {
        let suggestions = QuerySuggestionEngine.suggestions(for: "op:rename,unl", context: QuerySuggestionContext())

        XCTAssertEqual(suggestions.first?.resultText, "op:rename,unlink ")
    }

    func testOperationClassAndBooleanValues() {
        let classSuggestions = QuerySuggestionEngine.suggestions(for: "class:w", context: QuerySuggestionContext())
        XCTAssertEqual(classSuggestions.first?.resultText, "class:write ")

        let platform = QuerySuggestionEngine.suggestions(for: "platform:t", context: QuerySuggestionContext())
        XCTAssertEqual(platform.first?.resultText, "platform:true ")

        let apple = QuerySuggestionEngine.suggestions(for: "apple:", context: QuerySuggestionContext())
        XCTAssertEqual(apple.map(\.label), ["true", "false"])
    }

    func testProcessValuesComeFromContextAndQuoteWhitespace() {
        var context = QuerySuggestionContext()
        context.processNames = [
            (value: "Safari", detail: "1204 events"),
            (value: "My App", detail: nil),
        ]

        let prefixed = QuerySuggestionEngine.suggestions(for: "process:Saf", context: context)
        XCTAssertEqual(prefixed.first?.resultText, "process:Safari ")
        XCTAssertEqual(prefixed.first?.detail, "1204 events")

        let quoted = QuerySuggestionEngine.suggestions(for: "process:My", context: context)
        XCTAssertEqual(quoted.first?.resultText, "process:\"My App\" ")
    }

    func testComparisonOperatorIsPreserved() {
        var context = QuerySuggestionContext()
        context.teamIDs = [(value: "ABC123", detail: nil)]

        let suggestions = QuerySuggestionEngine.suggestions(for: "team!=ABC", context: context)

        XCTAssertEqual(suggestions.first?.resultText, "team!=ABC123 ")
    }

    func testSuppressedPositionsReturnNothing() {
        var context = QuerySuggestionContext()
        context.processNames = [(value: "My App", detail: nil)]

        XCTAssertTrue(QuerySuggestionEngine.suggestions(for: "process:\"My", context: context).isEmpty, "inside quotes")
        XCTAssertTrue(QuerySuggestionEngine.suggestions(for: "op:re*", context: context).isEmpty, "wildcard value")
        XCTAssertTrue(QuerySuggestionEngine.suggestions(for: "bogus:x", context: context).isEmpty, "unknown field")
        XCTAssertTrue(QuerySuggestionEngine.suggestions(for: "path:/Lib", context: context).isEmpty, "free-form path")
    }

    func testKeywordsFollowFieldSuggestions() {
        let notSuggestions = QuerySuggestionEngine.suggestions(for: "n", context: QuerySuggestionContext())
        XCTAssertTrue(notSuggestions.contains { $0.kind == .keyword && $0.label == "NOT" })
        XCTAssertEqual(notSuggestions.first?.kind, .field(.processName), "fields rank before keywords")

        let andSuggestions = QuerySuggestionEngine.suggestions(for: "a", context: QuerySuggestionContext())
        XCTAssertTrue(andSuggestions.contains { $0.kind == .keyword && $0.resultText == "AND " })

        let negated = QuerySuggestionEngine.suggestions(for: "-n", context: QuerySuggestionContext())
        XCTAssertFalse(negated.contains { $0.kind == .keyword }, "negated tokens never suggest keywords")
    }

    func testAcceptedSuggestionsAlwaysParseBackToTheirField() {
        for descriptor in MacFSWQueryFieldCatalog.descriptors where descriptor.field != .any {
            let fieldSuggestions = QuerySuggestionEngine.suggestions(
                for: descriptor.canonicalKey,
                context: QuerySuggestionContext()
            )
            guard let fieldSuggestion = fieldSuggestions.first(where: { $0.kind == .field(descriptor.field) }) else {
                XCTFail("typing \(descriptor.canonicalKey) must offer the \(descriptor.field) field")
                continue
            }
            XCTAssertEqual(fieldSuggestion.resultText, descriptor.canonicalKey + ":")

            switch descriptor.valueKind {
            case .eventType, .operationClass, .boolean:
                let valueSuggestions = QuerySuggestionEngine.suggestions(
                    for: fieldSuggestion.resultText,
                    context: QuerySuggestionContext()
                )
                guard let valueSuggestion = valueSuggestions.first else {
                    XCTFail("\(descriptor.canonicalKey): must offer enum values")
                    continue
                }
                let parsed = MacFSWQueryParser.parse(valueSuggestion.resultText)
                guard case .predicate(let predicate) = parsed.expression else {
                    XCTFail("accepted suggestion \(valueSuggestion.resultText) must parse to a predicate")
                    continue
                }
                XCTAssertEqual(predicate.field, descriptor.field)
            default:
                break
            }
        }
    }

    func testNextHighlightNavigation() {
        XCTAssertEqual(QuerySuggestionEngine.nextHighlight(current: nil, delta: 1, count: 5), 0)
        XCTAssertEqual(QuerySuggestionEngine.nextHighlight(current: nil, delta: -1, count: 5), 4)
        XCTAssertEqual(QuerySuggestionEngine.nextHighlight(current: 4, delta: 1, count: 5), 4)
        XCTAssertEqual(QuerySuggestionEngine.nextHighlight(current: 0, delta: -1, count: 5), 0)
        XCTAssertEqual(QuerySuggestionEngine.nextHighlight(current: 2, delta: 1, count: 5), 3)
        XCTAssertNil(QuerySuggestionEngine.nextHighlight(current: 2, delta: 1, count: 0))
    }

    func testCycledHighlightWrapsAtEdges() {
        XCTAssertEqual(QuerySuggestionEngine.cycledHighlight(current: nil, delta: 1, count: 5), 0)
        XCTAssertEqual(QuerySuggestionEngine.cycledHighlight(current: nil, delta: -1, count: 5), 4)
        XCTAssertEqual(QuerySuggestionEngine.cycledHighlight(current: 4, delta: 1, count: 5), 0)
        XCTAssertEqual(QuerySuggestionEngine.cycledHighlight(current: 0, delta: -1, count: 5), 4)
        XCTAssertEqual(QuerySuggestionEngine.cycledHighlight(current: 2, delta: 1, count: 5), 3)
        XCTAssertNil(QuerySuggestionEngine.cycledHighlight(current: 2, delta: 1, count: 0))
    }

    func testContextBuilderDedupesAndSortsCandidates() {
        let summaries = [
            makeSummary(id: "1", name: "Safari", pid: 100, eventCount: 10, lifecycle: .exited),
            makeSummary(id: "2", name: "Safari", pid: 101, eventCount: 900, lifecycle: .running),
            makeSummary(id: "3", name: "cfprefsd", pid: 200, eventCount: 40, lifecycle: .running, signing: ""),
        ]

        let context = QuerySuggestionEngine.context(from: summaries, history: ["op:write"])

        XCTAssertEqual(context.processNames.map(\.value), ["Safari", "cfprefsd"])
        XCTAssertEqual(context.processNames.first?.detail, "900 events")
        XCTAssertEqual(context.pids.map(\.value), ["101", "200", "100"], "running processes rank before exited ones")
        XCTAssertEqual(context.signingIDs.map(\.value), ["com.apple.Safari"], "empty signing summaries are dropped")
        XCTAssertEqual(context.history, ["op:write"])
    }

    private func makeSummary(
        id: String,
        name: String,
        pid: Int32,
        eventCount: Int,
        lifecycle: MacFSWProcessLifecycle,
        signing: String = "com.apple.Safari"
    ) -> MacFSWProcessSummary {
        MacFSWProcessSummary(
            id: id,
            processName: name,
            pid: pid,
            auditToken: "token-\(id)",
            executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            signingSummary: signing,
            uid: 501,
            gid: 20,
            eventCount: eventCount,
            lastEventNS: 0,
            isPlatformBinary: false,
            identityCount: 1,
            lifecycle: lifecycle
        )
    }
}
