import XCTest

@testable import MacFSWCore

final class QueryLexerTests: XCTestCase {
    func testKindsTextsAndRanges() {
        let source = "(op:rename OR -x) path:/Library"
        let stream = MacFSWQueryLexer.tokenize(source)

        XCTAssertEqual(
            stream.tokens.map(\.kind),
            [.leftParen, .word, .or, .not, .word, .rightParen, .word]
        )
        XCTAssertEqual(
            stream.tokens.map(\.text),
            ["(", "op:rename", "OR", "-", "x", ")", "path:/Library"]
        )
        XCTAssertEqual(
            stream.tokens.map { String(source[$0.range]) },
            ["(", "op:rename", "OR", "-", "x", ")", "path:/Library"]
        )
        XCTAssertFalse(stream.endsInsideQuotes)
        XCTAssertEqual(stream.source, source)
    }

    func testQuotedTokenStripsQuotesButRangeIncludesThem() {
        let source = "path:\"/My Folder\""
        let stream = MacFSWQueryLexer.tokenize(source)

        XCTAssertEqual(stream.tokens.count, 1)
        XCTAssertEqual(stream.tokens[0].kind, .word)
        XCTAssertEqual(stream.tokens[0].text, "path:/My Folder")
        XCTAssertEqual(String(source[stream.tokens[0].range]), "path:\"/My Folder\"")
    }

    func testQuotesDoNotProtectKeywords() {
        let stream = MacFSWQueryLexer.tokenize("\"AND\"")

        XCTAssertEqual(stream.tokens.map(\.kind), [.and])
        XCTAssertEqual(String(stream.source[stream.tokens[0].range]), "\"AND\"")
    }

    func testQuotesProtectWhitespaceAndParens() {
        let stream = MacFSWQueryLexer.tokenize("\"(a b)\"")

        XCTAssertEqual(stream.tokens.map(\.kind), [.word])
        XCTAssertEqual(stream.tokens[0].text, "(a b)")
    }

    func testDashSugarSplitsSpans() {
        let source = "-platform:true"
        let stream = MacFSWQueryLexer.tokenize(source)

        XCTAssertEqual(stream.tokens.map(\.kind), [.not, .word])
        XCTAssertEqual(String(source[stream.tokens[0].range]), "-")
        XCTAssertEqual(String(source[stream.tokens[1].range]), "platform:true")
        XCTAssertEqual(stream.tokens[1].text, "platform:true")
    }

    func testDashSugarDoesNotReclassifyRemainderAsKeyword() {
        let stream = MacFSWQueryLexer.tokenize("-AND")

        XCTAssertEqual(stream.tokens.map(\.kind), [.not, .word])
        XCTAssertEqual(stream.tokens[1].text, "AND")
    }

    func testLoneDashIsAWord() {
        let stream = MacFSWQueryLexer.tokenize("-")

        XCTAssertEqual(stream.tokens.map(\.kind), [.word])
        XCTAssertEqual(stream.tokens[0].text, "-")
    }

    func testKeywordsAreCaseInsensitive() {
        let stream = MacFSWQueryLexer.tokenize("a and b oR c Not d")

        XCTAssertEqual(
            stream.tokens.map(\.kind),
            [.word, .and, .word, .or, .word, .not, .word]
        )
        XCTAssertEqual(stream.tokens[1].text, "and", "keyword tokens keep their original spelling")
    }

    func testUnterminatedQuoteSetsFlag() {
        let stream = MacFSWQueryLexer.tokenize("path:\"/My Fol")

        XCTAssertTrue(stream.endsInsideQuotes)
        XCTAssertEqual(stream.tokens.map(\.text), ["path:/My Fol"])
    }

    func testEmptyQuotesProduceNoToken() {
        XCTAssertTrue(MacFSWQueryLexer.tokenize("\"\"").tokens.isEmpty)
        XCTAssertTrue(MacFSWQueryLexer.tokenize("   ").tokens.isEmpty)
        XCTAssertTrue(MacFSWQueryLexer.tokenize("").tokens.isEmpty)
    }

    func testMultibyteContentKeepsRangesValid() {
        let source = "process:\"微信 App\" path:/tmp"
        let stream = MacFSWQueryLexer.tokenize(source)

        XCTAssertEqual(stream.tokens.map(\.text), ["process:微信 App", "path:/tmp"])
        XCTAssertEqual(String(source[stream.tokens[0].range]), "process:\"微信 App\"")
        XCTAssertEqual(String(source[stream.tokens[1].range]), "path:/tmp")
    }
}
