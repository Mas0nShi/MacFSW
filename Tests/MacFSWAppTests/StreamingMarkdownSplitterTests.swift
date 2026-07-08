import XCTest

@testable import MacFSWApp

final class StreamingMarkdownSplitterTests: XCTestCase {
    func testSplitsAtLastBlankLineOutsideFence() {
        let markdown = "# Title\n\nFirst paragraph.\n\nSecond para still going"
        let parts = StreamingMarkdownSplitter.split(markdown)

        XCTAssertEqual(parts.stablePrefix, "# Title\n\nFirst paragraph.\n\n")
        XCTAssertEqual(parts.tail, "Second para still going")
    }

    func testBlankLineInsideFenceIsNotABoundary() {
        let markdown = "Intro\n\n```\ncode line\n\nstill the same code block"
        let parts = StreamingMarkdownSplitter.split(markdown)

        XCTAssertEqual(parts.stablePrefix, "Intro\n\n")
        XCTAssertEqual(parts.tail, "```\ncode line\n\nstill the same code block")
    }

    func testClosedFenceRestoresBoundaries() {
        let markdown = "Intro\n\n```\ncode\n```\n\nAfter fence tail"
        let parts = StreamingMarkdownSplitter.split(markdown)

        XCTAssertEqual(parts.stablePrefix, "Intro\n\n```\ncode\n```\n\n")
        XCTAssertEqual(parts.tail, "After fence tail")
    }

    func testNoBoundaryMeansEverythingIsTail() {
        let markdown = "single paragraph without any blank line"
        let parts = StreamingMarkdownSplitter.split(markdown)

        XCTAssertEqual(parts.stablePrefix, "")
        XCTAssertEqual(parts.tail, markdown)
    }

    func testTrailingBlankLineLeavesEmptyTail() {
        let markdown = "Done paragraph.\n\n"
        let parts = StreamingMarkdownSplitter.split(markdown)

        XCTAssertEqual(parts.stablePrefix, markdown)
        XCTAssertEqual(parts.tail, "")
    }

    func testTildeFenceIsRespected() {
        let markdown = "Intro\n\n~~~\ntext\n\ninside"
        let parts = StreamingMarkdownSplitter.split(markdown)

        XCTAssertEqual(parts.stablePrefix, "Intro\n\n")
        XCTAssertEqual(parts.tail, "~~~\ntext\n\ninside")
    }

    func testWhitespaceOnlyLineCountsAsBlank() {
        let markdown = "Para.\n   \nNext tail"
        let parts = StreamingMarkdownSplitter.split(markdown)

        XCTAssertEqual(parts.stablePrefix, "Para.\n   \n")
        XCTAssertEqual(parts.tail, "Next tail")
    }
}
