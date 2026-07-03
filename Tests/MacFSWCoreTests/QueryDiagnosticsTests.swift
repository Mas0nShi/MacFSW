import XCTest

@testable import MacFSWCore

final class QueryDiagnosticsTests: XCTestCase {
    func testUnknownFieldDiagnostic() {
        let result = MacFSWQueryParser.parseDetailed("porcess:Safari path:/tmp")

        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics[0].kind, .unknownField(name: "porcess"))
        XCTAssertEqual(sliced(result.diagnostics[0], in: "porcess:Safari path:/tmp"), "porcess:Safari")
        XCTAssertTrue(result.diagnostics[0].message.contains("porcess"))
    }

    func testEmptyValueDiagnostic() {
        let result = MacFSWQueryParser.parseDetailed("op:")

        XCTAssertEqual(result.diagnostics.map(\.kind), [.emptyValue(fieldText: "op")])
        XCTAssertEqual(sliced(result.diagnostics[0], in: "op:"), "op:")
    }

    func testUnterminatedQuoteDiagnostic() {
        let source = "path:\"/My Fol"
        let result = MacFSWQueryParser.parseDetailed(source)

        XCTAssertEqual(result.diagnostics.map(\.kind), [.unterminatedQuote])
        XCTAssertEqual(sliced(result.diagnostics[0], in: source), "\"/My Fol")
    }

    func testUnbalancedOpenParenDiagnostic() {
        let source = "((a)"
        let result = MacFSWQueryParser.parseDetailed(source)

        XCTAssertEqual(result.diagnostics.map(\.kind), [.unbalancedOpenParen])
        XCTAssertEqual(sliced(result.diagnostics[0], in: source), "(", "attributed to the unclosed open paren")
    }

    func testUnexpectedCloseParenDiagnostic() {
        let result = MacFSWQueryParser.parseDetailed("a ) b")

        XCTAssertEqual(result.diagnostics.map(\.kind), [.unexpectedCloseParen])
        XCTAssertEqual(result.query.expression, .predicate(MacFSWQueryPredicate(field: .any, comparison: .contains, values: ["a"])))
    }

    func testDanglingOperatorDiagnostics() {
        XCTAssertEqual(
            MacFSWQueryParser.parseDetailed("a AND").diagnostics.map(\.kind),
            [.danglingOperator(keyword: "AND")]
        )
        XCTAssertEqual(
            MacFSWQueryParser.parseDetailed("op:rename or").diagnostics.map(\.kind),
            [.danglingOperator(keyword: "OR")]
        )
        XCTAssertEqual(
            MacFSWQueryParser.parseDetailed("NOT").diagnostics.map(\.kind),
            [.danglingOperator(keyword: "NOT")]
        )
    }

    func testCleanQueriesProduceNoDiagnostics() {
        let inputs = [
            "",
            "op:rename",
            "(op:rename OR op:unlink) path:/Library NOT platform:true",
            "path:\"/My Folder\" team!=ABC seq>=100",
            "-platform:true op:rename,unlink",
        ]
        for input in inputs {
            XCTAssertEqual(
                MacFSWQueryParser.parseDetailed(input).diagnostics,
                [],
                "input: \(input)"
            )
        }
    }

    /// The load-bearing invariant: diagnostics NEVER change interpretation.
    /// Runs over the whole golden corpus plus every diagnostic trigger.
    func testDetailedParseMatchesPlainParseEverywhere() {
        let extraInputs = [
            "porcess:Safari", "op:", "path:\"/My Fol", "((a)", "a ) b",
            "a AND", "op:rename OR", "NOT", "NOT NOT", "bogus:",
        ]
        for input in QueryGoldenCorpusTests.corpus.map(\.input) + extraInputs {
            let detailed = MacFSWQueryParser.parseDetailed(input)
            XCTAssertEqual(detailed.query, MacFSWQueryParser.parse(input), "input: \(input)")
            XCTAssertEqual(detailed.tokens.source, input)
        }
    }

    private func sliced(_ diagnostic: MacFSWQueryDiagnostic, in source: String) -> String? {
        diagnostic.range.map { String(source[$0]) }
    }
}
