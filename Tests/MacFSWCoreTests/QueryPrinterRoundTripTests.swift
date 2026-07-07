import XCTest

@testable import MacFSWCore

final class QueryPrinterRoundTripTests: XCTestCase {
    func testCanonicalTextExamples() {
        XCTAssertEqual(print(anyContains("rename")), "rename")
        XCTAssertEqual(print(pred(.eventType, .contains, ["rename", "unlink"])), "op:rename,unlink")
        XCTAssertEqual(print(pred(.teamID, .notEquals, ["ABC"])), "team!=ABC")
        XCTAssertEqual(print(pred(.path, .contains, ["/My Folder"])), "path:\"/My Folder\"")
        // Keyword-spelled and operator-bearing values need the explicit any: form
        XCTAssertEqual(print(anyContains("AND")), "any:AND")
        XCTAssertEqual(print(anyContains("a=b")), "any:a=b")
        XCTAssertEqual(print(anyContains("-x")), "any:-x")
        XCTAssertEqual(
            print(.and([pred(.eventType, .contains, ["rename"]), .not(pred(.platformBinary, .contains, ["true"]))])),
            "op:rename (NOT platform:true)"
        )
        XCTAssertEqual(
            print(.or([.or([anyContains("a"), anyContains("b")]), anyContains("c")])),
            "(a OR b) OR c"
        )
    }

    /// parse ∘ print == identity over generated parser-canonical ASTs.
    /// Deterministic: fixed seeds, reproducible failures print seed + text.
    func testRoundTripProperty() {
        for seed: UInt64 in [1, 42, 2026, 0xDEAD_BEEF, 0x5EED] {
            var rng = SplitMix64(state: seed)
            for iteration in 0..<200 {
                let expression = makeExpression(&rng, depth: 0)
                let printed = MacFSWQueryPrinter.canonicalText(for: expression)
                let reparsed = MacFSWQueryParser.parse(printed).expression
                XCTAssertEqual(
                    reparsed,
                    expression,
                    "seed \(seed) iteration \(iteration): \(printed)"
                )
                XCTAssertEqual(
                    MacFSWQueryParser.parseDetailed(printed).diagnostics,
                    [],
                    "canonical text must never heal — seed \(seed): \(printed)"
                )
            }
        }
    }

    /// Out-of-domain closed-set values still round-trip structurally; they
    /// just carry an invalidValue diagnostic.
    func testInvalidValuesStillRoundTrip() {
        let expression = pred(.eventType, .contains, ["xxx"])
        let printed = MacFSWQueryPrinter.canonicalText(for: expression)
        let detailed = MacFSWQueryParser.parseDetailed(printed)

        XCTAssertEqual(detailed.query.expression, expression)
        XCTAssertEqual(detailed.diagnostics.map(\.kind), [.invalidValue(fieldText: "op", value: "xxx")])
    }

    // MARK: - Deterministic generator

    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(below bound: Int) -> Int {
            Int(next() % UInt64(bound))
        }

        mutating func pick<T>(_ items: [T]) -> T {
            items[int(below: items.count)]
        }
    }

    private func makeExpression(_ rng: inout SplitMix64, depth: Int) -> MacFSWQueryExpression {
        let leafBias = depth >= 4 ? 100 : 40 + depth * 15
        if rng.int(below: 100) < leafBias {
            return .predicate(makePredicate(&rng))
        }
        switch rng.int(below: 3) {
        case 0:
            return .not(makeExpression(&rng, depth: depth + 1))
        case 1:
            let arity = 2 + rng.int(below: 2)
            return .and((0..<arity).map { _ in makeExpression(&rng, depth: depth + 1) })
        default:
            let arity = 2 + rng.int(below: 2)
            return .or((0..<arity).map { _ in makeExpression(&rng, depth: depth + 1) })
        }
    }

    private func makePredicate(_ rng: inout SplitMix64) -> MacFSWQueryPredicate {
        let descriptor = rng.pick(MacFSWQueryFieldCatalog.descriptors)
        let comparison = rng.pick(
            [MacFSWQueryComparison.contains, .equals, .notEquals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual]
        )
        let valueCount = 1 + rng.int(below: 3)
        // Closed-domain fields draw from their legal value sets so canonical
        // text stays diagnostic-free (the invalidValue check would fire on
        // arbitrary strings — see testInvalidValuesStillRoundTrip for the
        // structural property on out-of-domain values).
        var values: [String]
        switch descriptor.valueKind {
        case .eventType:
            values = (0..<valueCount).map { _ in rng.pick(MacFSWEventType.allCases).rawValue }
        case .operationClass:
            values = (0..<valueCount).map { _ in rng.pick(MacFSWOperationClass.allCases).rawValue }
        case .boolean:
            values = (0..<valueCount).map { _ in rng.pick(["true", "false", "yes", "no", "1", "0", "on", "off"]) }
        case .processName, .pid, .executable, .signingID, .teamID, .path, .numeric, .text:
            values = (0..<valueCount).map { _ in makeValue(&rng) }
        }
        // Representational limit (documented): after a printed "<" or ">",
        // a first value starting with "=" merges into "<="/">=" — such
        // predicates cannot be written as query text.
        if comparison == .lessThan || comparison == .greaterThan, values[0].hasPrefix("=") {
            values[0] = "x" + values[0]
        }
        return MacFSWQueryPredicate(field: descriptor.field, comparison: comparison, values: values)
    }

    /// Values exclude `"` and `,` (unrepresentable — see printer docs) and
    /// never carry leading/trailing whitespace (comma splitting trims ends).
    private func makeValue(_ rng: inout SplitMix64) -> String {
        let chunkAlphabet = Array("abcxyz019/._*-=:<>()!ANDORNOT")
        func chunk() -> String {
            let length = 1 + rng.int(below: 6)
            return String((0..<length).map { _ in rng.pick(chunkAlphabet) })
        }
        let chunkCount = 1 + rng.int(below: 2)
        return (0..<chunkCount).map { _ in chunk() }.joined(separator: " ")
    }

    // MARK: - Helpers

    private func print(_ expression: MacFSWQueryExpression) -> String {
        MacFSWQueryPrinter.canonicalText(for: expression)
    }

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
