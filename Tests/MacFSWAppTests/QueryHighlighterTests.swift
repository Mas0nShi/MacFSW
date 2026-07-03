import AppKit
import MacFSWCore
import XCTest

@testable import MacFSWApp

@MainActor
final class QueryHighlighterTests: XCTestCase {
    func testFieldKeysKeywordsAndParens() {
        let source = "(op:rename OR -x) path:/tmp"
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed(source))
        let texts = runs.map { (source as NSString).substring(with: $0.range) }

        XCTAssertEqual(texts, ["(", "op:", "OR", "-", ")", "path:"])
        XCTAssertTrue(runs[1].attributes[.foregroundColor] as? NSColor === NSColor.controlAccentColor)
        XCTAssertTrue(runs[2].attributes[.foregroundColor] as? NSColor === NSColor.secondaryLabelColor)
    }

    func testUnknownFieldGetsUnderlineRun() {
        let source = "porcess:Safari"
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed(source))

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual((source as NSString).substring(with: runs[0].range), "porcess:Safari")
        XCTAssertEqual(runs[0].attributes[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testQuotedValueRun() {
        let source = "path:\"/My Folder\""
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed(source))
        let texts = runs.map { (source as NSString).substring(with: $0.range) }

        XCTAssertEqual(texts, ["path:", "\"/My Folder\""])
    }

    func testMultibyteValuesKeepNSRangesAligned() {
        let source = "process:微信 op:rename"
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed(source))
        let texts = runs.map { (source as NSString).substring(with: $0.range) }

        XCTAssertEqual(texts, ["process:", "op:"])
    }

    func testPlainTermsProduceNoRuns() {
        let runs = QueryHighlighter.attributeRuns(for: MacFSWQueryParser.parseDetailed("rename /tmp"))
        XCTAssertTrue(runs.isEmpty)
    }
}
