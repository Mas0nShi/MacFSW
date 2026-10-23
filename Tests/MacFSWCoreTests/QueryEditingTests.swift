import XCTest
@testable import MacFSWCore

final class QueryEditingTests: XCTestCase {
    private let pid412 = MacFSWQueryEditor.term(.pid, "412")!

    func testPinningAProcessReplacesOnlyTopLevelPIDTerms() {
        XCTAssertEqual(MacFSWQueryEditor.editing("", removing: MacFSWQueryEditor.isPIDTerm, adding: [pid412]), "pid:412")
        XCTAssertEqual(
            MacFSWQueryEditor.editing("op:write pid:7 path:/Library", removing: MacFSWQueryEditor.isPIDTerm, adding: [pid412]),
            "op:write path:/Library pid:412"
        )
        XCTAssertEqual(
            MacFSWQueryEditor.editing("op:write OR pid:7", removing: MacFSWQueryEditor.isPIDTerm, adding: [pid412]),
            "(op:write OR pid:7) pid:412",
            "a pid inside OR is part of a different condition and stays"
        )
        XCTAssertEqual(MacFSWQueryEditor.editing("op:write pid:412", removing: MacFSWQueryEditor.isPIDTerm), "op:write")
    }

    func testEditedTextParsesBackToTheSameQuery() {
        let edited = MacFSWQueryEditor.editing(
            "(op:rename OR op:unlink) -process:mdworker",
            adding: [MacFSWQueryEditor.term(.targetPath, "/Users/me/My Files")!]
        )
        let reparsed = MacFSWQueryParser.parse(edited).expression
        XCTAssertEqual(MacFSWQueryPrinter.canonicalText(for: reparsed!), edited)
        XCTAssertTrue(edited.contains("\"/Users/me/My Files\""))
    }

    func testUnrepresentableValuesAreRefused() {
        XCTAssertNil(MacFSWQueryEditor.term(.targetPath, "/tmp/a,b"))
        XCTAssertNil(MacFSWQueryEditor.term(.targetPath, "/tmp/\"x\""))
        XCTAssertNotNil(MacFSWQueryEditor.term(.processName, "mdworker", negated: true))
    }

    func testPinnedPID() {
        XCTAssertEqual(MacFSWQueryEditor.pinnedPID(in: "op:write pid:412"), 412)
        XCTAssertNil(MacFSWQueryEditor.pinnedPID(in: "pid:1 pid:2"))
        XCTAssertNil(MacFSWQueryEditor.pinnedPID(in: "op:write OR pid:412"))
    }
}
