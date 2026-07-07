import XCTest

@testable import MacFSWCore

final class QueryCursorContextTests: XCTestCase {
    func testBarePositions() {
        assertBare("", prefix: "", prefixText: "")
        assertBare("op", prefix: "op", prefixText: "")
        assertBare("op:rename ", prefix: "", prefixText: "op:rename ")
        assertBare("a AND b", prefix: "b", prefixText: "a AND ")
        assertBare("(a) ", prefix: "", prefixText: "(a) ")
    }

    func testFieldValuePositions() {
        let empty = MacFSWQueryCursorContext.trailing(of: "op:")
        guard case .fieldValue(let descriptor, "op", ":", "", "") = empty.position else {
            return XCTFail("op: must be a field-value position with an empty prefix, got \(empty.position)")
        }
        XCTAssertEqual(descriptor.field, .eventType)

        let partial = MacFSWQueryCursorContext.trailing(of: "x op:re")
        guard case .fieldValue(_, "op", ":", "", "re") = partial.position else {
            return XCTFail("got \(partial.position)")
        }
        XCTAssertEqual(partial.prefixText, "x ")

        let comma = MacFSWQueryCursorContext.trailing(of: "op:rename,unl")
        guard case .fieldValue(_, "op", ":", "rename,", "unl") = comma.position else {
            return XCTFail("got \(comma.position)")
        }

        let comparison = MacFSWQueryCursorContext.trailing(of: "team!=AB")
        guard case .fieldValue(let teamDescriptor, "team", "!=", "", "AB") = comparison.position else {
            return XCTFail("got \(comparison.position)")
        }
        XCTAssertEqual(teamDescriptor.field, .teamID)

        // Leftmost-longest, same as the parser
        let leftmost = MacFSWQueryCursorContext.trailing(of: "path:/foo=ba")
        guard case .fieldValue(let pathDescriptor, "path", ":", "", "/foo=ba") = leftmost.position else {
            return XCTFail("got \(leftmost.position)")
        }
        XCTAssertEqual(pathDescriptor.field, .path)
    }

    func testNegationAndParenPrefixes() {
        let negated = MacFSWQueryCursorContext.trailing(of: "-o")
        XCTAssertTrue(negated.isNegated)
        XCTAssertEqual(negated.prefixText, "-")
        XCTAssertEqual(negated.position, .bare(prefix: "o"))

        let loneDash = MacFSWQueryCursorContext.trailing(of: "-")
        XCTAssertTrue(loneDash.isNegated)
        XCTAssertEqual(loneDash.prefixText, "-")
        XCTAssertEqual(loneDash.position, .bare(prefix: ""))

        let paren = MacFSWQueryCursorContext.trailing(of: "(op:re")
        XCTAssertEqual(paren.prefixText, "(")
        guard case .fieldValue(_, "op", ":", "", "re") = paren.position else {
            return XCTFail("got \(paren.position)")
        }
    }

    func testQuoteStates() {
        XCTAssertEqual(MacFSWQueryCursorContext.trailing(of: "process:\"My").position, .insideQuotes)

        // Balanced quotes stay part of the trailing token body verbatim
        let balanced = MacFSWQueryCursorContext.trailing(of: "path:\"/a b\"")
        guard case .fieldValue(_, "path", ":", "", "\"/a b\"") = balanced.position else {
            return XCTFail("got \(balanced.position)")
        }
    }

    func testUnknownField() {
        let context = MacFSWQueryCursorContext.trailing(of: "bogus:x")
        XCTAssertEqual(context.position, .unknownField(fieldText: "bogus"))
    }

    /// Drift suite 1: for text ending in a complete field term, the cursor
    /// context and the parser MUST agree on the field. This is the permanent
    /// guard that completion positions and parse results cannot diverge.
    func testCursorFieldAgreesWithParserOnCompleteTerms() {
        let inputs = [
            "op:rename",
            "x path:/tmp",
            "a AND team!=ABC",
            "(op:rename OR op:unlink) platform:true",
            "NOT apple:false",
            "-mutation:true",
            "seq>=100",
            "path:/foo=bar",
            "detail:key=value",
            "op:rename,unlink",
        ]
        for input in inputs {
            let context = MacFSWQueryCursorContext.trailing(of: input)
            guard case .fieldValue(let descriptor, _, _, _, _) = context.position else {
                XCTFail("\(input) should be a field-value position, got \(context.position)")
                continue
            }
            guard let parsed = MacFSWQueryParser.parse(input).expression,
                  let lastField = rightmostPredicate(in: parsed)?.field else {
                XCTFail("\(input) should parse to a predicate")
                continue
            }
            XCTAssertEqual(descriptor.field, lastField, "input: \(input)")
        }
    }

    /// Drift suite 2: prefixText + trailing token body reconstruct the input
    /// exactly, over the whole golden corpus.
    func testPrefixAndBodyReconstructInput() {
        for input in QueryGoldenCorpusTests.corpus.map(\.input) {
            let context = MacFSWQueryCursorContext.trailing(of: input)
            let body: String
            switch context.position {
            case .insideQuotes:
                continue
            case .bare(let prefix):
                body = prefix
            case .fieldValue(_, let fieldText, let operatorText, let priorValues, let valuePrefix):
                body = fieldText + operatorText + priorValues + valuePrefix
            case .unknownField:
                continue // fieldText alone cannot reconstruct; covered by unit tests
            }
            XCTAssertEqual(context.prefixText + body, input, "input: \(input)")
        }
    }

    /// Drift suite 3: quote state agrees with the lexer everywhere.
    func testQuoteStateAgreesWithLexer() {
        for input in QueryGoldenCorpusTests.corpus.map(\.input) + ["a \"b", "\"", "x\"y\"z"] {
            let context = MacFSWQueryCursorContext.trailing(of: input)
            XCTAssertEqual(
                context.position == .insideQuotes,
                MacFSWQueryLexer.tokenize(input).endsInsideQuotes,
                "input: \(input)"
            )
        }
    }

    // MARK: - Helpers

    private func assertBare(
        _ input: String,
        prefix: String,
        prefixText: String,
        line: UInt = #line
    ) {
        let context = MacFSWQueryCursorContext.trailing(of: input)
        XCTAssertEqual(context.position, .bare(prefix: prefix), "input: \(input)", line: line)
        XCTAssertEqual(context.prefixText, prefixText, "input: \(input)", line: line)
    }

    private func rightmostPredicate(in expression: MacFSWQueryExpression) -> MacFSWQueryPredicate? {
        switch expression {
        case .predicate(let predicate):
            return predicate
        case .not(let operand):
            return rightmostPredicate(in: operand)
        case .and(let children), .or(let children):
            return children.last.flatMap(rightmostPredicate(in:))
        }
    }
}
