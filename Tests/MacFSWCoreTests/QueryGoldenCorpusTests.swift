import Foundation
import XCTest

@testable import MacFSWCore

/// Characterization tests: this corpus freezes the OBSERVED behavior of the
/// query front-end so the lexer/parser re-architecture can prove it is
/// bit-identical. Entries here are contracts; changing one requires a
/// behavior-change ledger entry in docs/query-syntax.md.
final class QueryGoldenCorpusTests: XCTestCase {
    private struct Case {
        let input: String
        let expected: MacFSWQueryExpression?
        let line: UInt

        init(_ input: String, _ expected: MacFSWQueryExpression?, line: UInt = #line) {
            self.input = input
            self.expected = expected
            self.line = line
        }
    }

    func testGoldenCorpus() {
        let corpus: [Case] = [
            // Bare words → full-text contains
            Case("rename", anyContains("rename")),
            Case("  rename  ", anyContains("rename")),
            Case("two words", .and([anyContains("two"), anyContains("words")])),

            // Field terms, canonical and aliased keys
            Case("op:rename", pred(.eventType, .contains, ["rename"])),
            Case("EVENT_TYPE:rename", pred(.eventType, .contains, ["rename"])),
            Case("process:Safari", pred(.processName, .contains, ["Safari"])),
            Case("pname:Safari", pred(.processName, .contains, ["Safari"])),
            Case("path:/Library", pred(.path, .contains, ["/Library"])),
            Case("apple:false", pred(.appleControlled, .contains, ["false"])),
            Case("uid:501", pred(.uid, .contains, ["501"])),
            Case("user:501", pred(.uid, .contains, ["501"])),

            // Comparison operators
            Case("team!=ABC", pred(.teamID, .notEquals, ["ABC"])),
            Case("seq>=100", pred(.sequence, .greaterOrEqual, ["100"])),
            Case("seq<=100", pred(.sequence, .lessOrEqual, ["100"])),
            Case("pid>10", pred(.pid, .greaterThan, ["10"])),
            Case("pid<10", pred(.pid, .lessThan, ["10"])),
            Case("flags=0x10", pred(.flags, .equals, ["0x10"])),

            // Comma-separated multi-values (empties filtered, whitespace trimmed by split)
            Case("op:rename,unlink", pred(.eventType, .contains, ["rename", "unlink"])),
            Case("op:rename,,unlink", pred(.eventType, .contains, ["rename", "unlink"])),
            // A trailing comma leaves a single value; the comma splits inside the token only
            Case("op:rename,", pred(.eventType, .contains, ["rename"])),
            // Comma does NOT join across whitespace: second word is full-text
            Case("op:rename, unlink", .and([pred(.eventType, .contains, ["rename"]), anyContains("unlink")])),

            // Implicit AND, explicit AND/OR, precedence, parentheses
            Case("op:rename path:/Library", .and([pred(.eventType, .contains, ["rename"]), pred(.path, .contains, ["/Library"])])),
            Case("a AND b", .and([anyContains("a"), anyContains("b")])),
            Case("a and b", .and([anyContains("a"), anyContains("b")])),
            Case("op:rename OR op:unlink", .or([pred(.eventType, .contains, ["rename"]), pred(.eventType, .contains, ["unlink"])])),
            Case("a oR b", .or([anyContains("a"), anyContains("b")])),
            Case(
                "a b OR c",
                .or([.and([anyContains("a"), anyContains("b")]), anyContains("c")])
            ),
            Case(
                "(op:rename OR op:unlink) path:/Library",
                .and([
                    .or([pred(.eventType, .contains, ["rename"]), pred(.eventType, .contains, ["unlink"])]),
                    pred(.path, .contains, ["/Library"]),
                ])
            ),
            Case("a OR b OR c", .or([anyContains("a"), anyContains("b"), anyContains("c")])),
            // Parenthesized OR nested inside a chain is NOT flattened
            Case("(a OR b) OR c", .or([.or([anyContains("a"), anyContains("b")]), anyContains("c")])),

            // NOT and "-" sugar; NOT binds tighter than AND
            Case("NOT platform:true", .not(pred(.platformBinary, .contains, ["true"]))),
            Case("not platform:true", .not(pred(.platformBinary, .contains, ["true"]))),
            Case("-platform:true", .not(pred(.platformBinary, .contains, ["true"]))),
            Case("NOT a b", .and([.not(anyContains("a")), anyContains("b")])),
            Case("NOT (a OR b)", .not(.or([anyContains("a"), anyContains("b")]))),
            Case("NOT NOT a", .not(.not(anyContains("a")))),
            // "-" alone is a plain word (sugar needs len > 1)
            Case("-", anyContains("-")),
            // "-" sugar does NOT re-classify the remainder as a keyword
            Case("-AND", .not(anyContains("AND"))),
            Case("x -y", .and([anyContains("x"), .not(anyContains("y"))])),

            // Quoting: protects whitespace and parens — NOT keywords, operators, commas
            Case("path:\"/My Folder\"", pred(.path, .contains, ["/My Folder"])),
            Case("\"two words\"", anyContains("two words")),
            Case("\"(literal)\"", anyContains("(literal)")),
            Case("\"AND\"", nil), // quotes are stripped before keyword classification
            Case("\"op:rename\"", pred(.eventType, .contains, ["rename"])), // and before operator split
            Case("op:\"a,b\"", pred(.eventType, .contains, ["a", "b"])), // and before comma split
            Case("\"unclosed", anyContains("unclosed")),
            Case("path:\"/a b\"/c", pred(.path, .contains, ["/a b/c"])),

            // Lenient healing: dangling operators dropped, stray parens ignored
            Case("", nil),
            Case("   ", nil),
            Case("AND", nil),
            Case("NOT", nil),
            Case("a AND", anyContains("a")),
            Case("op:rename OR", pred(.eventType, .contains, ["rename"])),
            Case(")", nil),
            Case("a )", anyContains("a")),
            Case("((a)", anyContains("a")),
            Case("()", nil),

            // Unknown fields and empty values silently degrade to full text
            Case("porcess:Safari", anyContains("porcess:Safari")),
            Case("op:", anyContains("op:")),
            Case(":value", anyContains(":value")),

            // Wildcards pass through as values
            Case("path:/Library/*", pred(.path, .contains, ["/Library/*"])),
            Case("team:UYF*", pred(.teamID, .contains, ["UYF*"])),
        ]

        for entry in corpus {
            let query = MacFSWQueryParser.parse(entry.input)
            XCTAssertEqual(
                query.expression,
                entry.expected,
                "input: \(entry.input)",
                line: entry.line
            )
            XCTAssertEqual(
                query.text,
                entry.input.trimmingCharacters(in: .whitespacesAndNewlines),
                line: entry.line
            )
        }
    }

    /// Operator scan-order ledger. CURRENT behavior scans operators in the
    /// fixed list order ["!=", ">=", "<=", "=", ":", ">", "<"], so a word
    /// whose leftmost operator is not first in that list mis-splits and
    /// degrades to full text. Phase 3 replaces this with leftmost-longest
    /// matching and REWRITES the expectations below.
    func testOperatorScanOrderLedger() {
        XCTAssertEqual(
            MacFSWQueryParser.parse("path:/foo=bar").expression,
            anyContains("path:/foo=bar")
        )
        XCTAssertEqual(
            MacFSWQueryParser.parse("op:a=b").expression,
            anyContains("op:a=b")
        )
        XCTAssertEqual(
            MacFSWQueryParser.parse("detail:key=value").expression,
            anyContains("detail:key=value")
        )
    }

    /// Tripwire for the persisted wire format: session archives store
    /// [MacFSWSavedQuery] as JSON (SQLiteEventStore `savedQueriesJSON`).
    /// The JSON below was captured from JSONEncoder.macfsw output and MUST
    /// keep decoding forever; breaking it breaks users' session archives.
    func testExpressionCodableWireFormatIsFrozen() throws {
        let expression = MacFSWQueryExpression.and([
            .or([
                .predicate(MacFSWQueryPredicate(field: .eventType, comparison: .equals, values: ["rename"])),
                .not(.predicate(MacFSWQueryPredicate(field: .platformBinary, comparison: .contains, values: ["true"]))),
            ]),
            .predicate(MacFSWQueryPredicate(field: .path, comparison: .contains, values: ["/Library", "/tmp"])),
        ])

        let frozenJSON = #"{"and":{"_0":[{"or":{"_0":[{"predicate":{"_0":{"field":"eventType","comparison":"equals","values":["rename"]}}},{"not":{"_0":{"predicate":{"_0":{"values":["true"],"comparison":"contains","field":"platformBinary"}}}}}]}},{"predicate":{"_0":{"comparison":"contains","values":["\/Library","\/tmp"],"field":"path"}}}]}}"#

        let decoded = try JSONDecoder.macfsw.decode(
            MacFSWQueryExpression.self,
            from: Data(frozenJSON.utf8)
        )
        XCTAssertEqual(decoded, expression)

        let reEncoded = try JSONEncoder.macfsw.encode(expression)
        XCTAssertEqual(
            try JSONDecoder.macfsw.decode(MacFSWQueryExpression.self, from: reEncoded),
            expression
        )
    }

    // MARK: - Helpers

    private func pred(
        _ field: MacFSWQueryField,
        _ comparison: MacFSWQueryComparison,
        _ values: [String]
    ) -> MacFSWQueryExpression {
        .predicate(MacFSWQueryPredicate(field: field, comparison: comparison, values: values))
    }

    private func anyContains(_ value: String) -> MacFSWQueryExpression {
        pred(.any, .contains, [value])
    }
}
