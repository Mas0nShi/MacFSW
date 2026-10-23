import MacFSWCore
import XCTest

final class EventChangeSummaryTests: XCTestCase {
    private func summary(_ type: MacFSWEventType, _ parameters: [String: String]) -> String {
        MacFSWFileEvent.operationDetailSummary(
            eventType: type,
            sourcePath: nil,
            parameters: parameters.map { MacFSWEventParameter(key: $0.key, label: $0.key, value: $0.value) }
        )
    }

    func testChmodShowsSymbolicBeforeAndAfter() {
        XCTAssertEqual(summary(.chmod, ["mode": "4755", "current_mode": "0644"]), "rw-r--r-- → rwsr-xr-x (4755)")
        XCTAssertEqual(summary(.chmod, ["mode": "1777", "current_mode": "1777"]), "rwxrwxrwt (1777)")
    }

    func testChownNamesOwnersAndKeepsUnchangedSides() {
        XCTAssertEqual(summary(.chown, ["uid": "0", "gid": "unchanged", "current_uid": "501", "current_gid": "0"]).hasSuffix("→ root:wheel"), true)
        XCTAssertEqual(summary(.chown, ["uid": "unchanged", "gid": "unchanged", "current_uid": "0", "current_gid": "0"]), "root:wheel")
    }

    func testSetflagsListsAddedAndRemovedFlags() {
        XCTAssertEqual(summary(.setflags, ["flags": "0x8000", "current_flags": "0x2"]), "+hidden −uchg")
        XCTAssertEqual(summary(.setflags, ["flags": "0x0", "current_flags": "0x0"]), "flags unchanged")
    }

    func testOperationsWithoutParametersSayNothing() {
        XCTAssertEqual(summary(.write, [:]), "")
        XCTAssertEqual(summary(.rename, ["destination_type": "new"]), "")
        XCTAssertEqual(summary(.rename, ["destination_type": "existing"]), "replaced an existing file")
        XCTAssertEqual(summary(.setextattr, ["xattr": "com.apple.quarantine"]), "com.apple.quarantine")
    }
}
