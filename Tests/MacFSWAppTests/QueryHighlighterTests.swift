import AppKit
import MacFSWCore
import XCTest

@testable import MacFSWApp

@MainActor
final class QueryHighlighterTests: XCTestCase {
    func testFieldTermsGetCapsuleAndKeyRuns() {
        let source = "(op:rename OR -x) path:/tmp"
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed(source))
        let texts = runs.map { (source as NSString).substring(with: $0.range) }

        // Per field term: whole-term capsule run, then key+operator run.
        XCTAssertEqual(texts, ["(", "op:rename", "op:", "OR", "-", ")", "path:/tmp", "path:"])

        let capsule = runs[1]
        XCTAssertTrue(capsule.attributes[.queryTokenBackground] as? NSColor === QueryHighlighter.tokenBackground)
        let key = runs[2]
        XCTAssertTrue(key.attributes[.foregroundColor] as? NSColor === NSColor.secondaryLabelColor)
        let keyword = runs[3]
        XCTAssertTrue(keyword.attributes[.foregroundColor] as? NSColor === NSColor.secondaryLabelColor)
        XCTAssertNil(keyword.attributes[.queryTokenBackground], "keywords never get capsules")
    }

    func testUnknownFieldGetsOrangeCapsule() {
        let source = "porcess:Safari"
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed(source))

        XCTAssertEqual((source as NSString).substring(with: runs[0].range), "porcess:Safari")
        XCTAssertTrue(runs[0].attributes[.queryTokenBackground] as? NSColor === QueryHighlighter.unknownTokenBackground)
    }

    func testQuotedValueStaysInsideOneCapsule() {
        let source = "path:\"/My Folder\""
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed(source))
        let texts = runs.map { (source as NSString).substring(with: $0.range) }

        XCTAssertEqual(texts, ["path:\"/My Folder\"", "path:"])
    }

    func testMultibyteValuesKeepNSRangesAligned() {
        let source = "process:微信 op:rename"
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed(source))
        let texts = runs.map { (source as NSString).substring(with: $0.range) }

        XCTAssertEqual(texts, ["process:微信", "process:", "op:rename", "op:"])
    }

    func testPlainTermsProduceNoRuns() {
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed("rename /tmp"))
        XCTAssertTrue(runs.isEmpty)
    }
}
