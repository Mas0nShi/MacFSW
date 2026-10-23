import AppKit
import MacFSWCore
import XCTest
@testable import MacFSWApp

@MainActor
final class EventTableCellTests: XCTestCase {
    func testCellsReadAsStaticTextWithTheirFullContent() {
        let process = MacFSWProcessIdentity(pid: 9, auditToken: "t", executablePath: "/bin/tool", processName: "tool")
        let row = MacFSWEventRowSummary(event: MacFSWFileEvent(
            eventType: .rename,
            process: process,
            targetPath: "/tmp/new.txt",
            sourcePath: "/tmp/old.txt"
        ))
        let cell = EventTableCellView(identifier: NSUserInterfaceItemIdentifier("path"))
        EventTableColumn.path.configure(cell, with: row)

        XCTAssertTrue(cell.isAccessibilityElement())
        XCTAssertEqual(cell.accessibilityRole(), .staticText)
        XCTAssertEqual(cell.accessibilityValue() as? String, "/tmp/old.txt  →  new.txt")

        EventTableColumn.process.configure(cell, with: row)
        XCTAssertEqual(cell.text, "tool  9")
    }
}
