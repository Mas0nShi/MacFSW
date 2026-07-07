import XCTest

@testable import MacFSWApp

final class ExecutableSecurityInspectorTests: XCTestCase {
    func testSymbolicModeForSUIDRootExecutable() {
        let permissions = FilePermissionSnapshot(mode: S_IFREG | 0o4755, owner: "root", group: "wheel")

        XCTAssertEqual(permissions.symbolic, "-rwsr-xr-x")
        XCTAssertEqual(permissions.octal, "4755")
        XCTAssertTrue(permissions.isSetUserID)
        XCTAssertFalse(permissions.isSetGroupID)
        XCTAssertEqual(permissions.displayText, "-rwsr-xr-x 4755 root:wheel")
    }

    func testSymbolicModeMarksSetUIDWithoutExecuteAsCapitalS() {
        let permissions = FilePermissionSnapshot(mode: S_IFREG | 0o4644, owner: "root", group: "wheel")

        XCTAssertEqual(permissions.symbolic, "-rwSr--r--")
    }

    func testSymbolicModeForSetGIDStickyDirectory() {
        let permissions = FilePermissionSnapshot(mode: S_IFDIR | 0o3777, owner: "root", group: "admin")

        XCTAssertEqual(permissions.symbolic, "drwxrwsrwt")
        XCTAssertEqual(permissions.octal, "3777")
        XCTAssertTrue(permissions.isSetGroupID)
        XCTAssertTrue(permissions.isSticky)
    }

    func testSymbolicModeForPlainFileAndSymlink() {
        XCTAssertEqual(FilePermissionSnapshot(mode: S_IFREG | 0o644, owner: "mason", group: "staff").symbolic, "-rw-r--r--")
        XCTAssertEqual(FilePermissionSnapshot(mode: S_IFLNK | 0o755, owner: "mason", group: "staff").symbolic, "lrwxr-xr-x")
        XCTAssertEqual(FilePermissionSnapshot(mode: S_IFREG | 0o644, owner: "mason", group: "staff").octal, "0644")
    }

    func testFileFlagsForSIPProtectedNode() {
        let permissions = FilePermissionSnapshot(
            mode: S_IFREG | 0o755,
            owner: "root",
            group: "wheel",
            flags: UInt32(SF_RESTRICTED) | UInt32(SF_NOUNLINK)
        )

        XCTAssertEqual(permissions.fileFlags.map(\.name), ["restricted", "sunlnk"])
        XCTAssertTrue(permissions.fileFlags.allSatisfy(\.isSystemEnforced))
        XCTAssertEqual(permissions.displayText, "-rwxr-xr-x 0755 root:wheel restricted,sunlnk")
    }

    func testFileFlagsIgnoreNoiseAndMarkUserScope() {
        let compressed = UInt32(UF_COMPRESSED)
        let permissions = FilePermissionSnapshot(
            mode: S_IFREG | 0o644,
            owner: "mason",
            group: "staff",
            flags: compressed | UInt32(UF_IMMUTABLE) | UInt32(UF_HIDDEN)
        )

        XCTAssertEqual(permissions.fileFlags.map(\.name), ["uchg", "hidden"])
        XCTAssertTrue(permissions.fileFlags.allSatisfy { !$0.isSystemEnforced })

        let plain = FilePermissionSnapshot(mode: S_IFREG | 0o644, owner: "mason", group: "staff")
        XCTAssertTrue(plain.fileFlags.isEmpty)
        XCTAssertEqual(plain.displayText, "-rw-r--r-- 0644 mason:staff")
    }

    func testSandboxStatusRule() {
        XCTAssertEqual(
            ExecutableSecurityInspector.sandboxStatus(
                entitlements: ["com.apple.security.app-sandbox": true],
                signingReadFailed: false
            ),
            .sandboxed
        )
        XCTAssertEqual(
            ExecutableSecurityInspector.sandboxStatus(
                entitlements: ["com.apple.security.app-sandbox": false],
                signingReadFailed: false
            ),
            .notSandboxed
        )
        XCTAssertEqual(
            ExecutableSecurityInspector.sandboxStatus(entitlements: [:], signingReadFailed: false),
            .notSandboxed
        )
        XCTAssertEqual(
            ExecutableSecurityInspector.sandboxStatus(entitlements: nil, signingReadFailed: false),
            .notSandboxed
        )
        XCTAssertEqual(
            ExecutableSecurityInspector.sandboxStatus(entitlements: nil, signingReadFailed: true),
            .unknown
        )
    }

    func testEntitlementEntryKeepsArrayStructure() {
        let list = ExecutableSecurityInspector.entitlementEntry(
            key: "com.apple.security.exception.mach-lookup.global-name",
            value: ["com.apple.calaccessd", "com.apple.feedbacklogger"]
        )
        XCTAssertEqual(list.items, ["com.apple.calaccessd", "com.apple.feedbacklogger"])
        XCTAssertEqual(list.value, "com.apple.calaccessd, com.apple.feedbacklogger")

        let scalar = ExecutableSecurityInspector.entitlementEntry(key: "com.apple.security.app-sandbox", value: true)
        XCTAssertTrue(scalar.items.isEmpty)
        XCTAssertEqual(scalar.value, "true")
    }

    func testRenderedEntitlementValues() {
        XCTAssertEqual(ExecutableSecurityInspector.renderedEntitlementValue(true), "true")
        XCTAssertEqual(ExecutableSecurityInspector.renderedEntitlementValue(false), "false")
        XCTAssertEqual(ExecutableSecurityInspector.renderedEntitlementValue(42), "42")
        XCTAssertEqual(ExecutableSecurityInspector.renderedEntitlementValue("com.example.group"), "com.example.group")
        XCTAssertEqual(
            ExecutableSecurityInspector.renderedEntitlementValue(["a.group", "b.group"]),
            "a.group, b.group"
        )
        XCTAssertEqual(
            ExecutableSecurityInspector.renderedEntitlementValue(["zeta": true, "alpha": "x"]),
            "alpha: x, zeta: true"
        )
    }

    func testReportReadsSandboxAndPermissionsOfRealBinaries() async throws {
        let inspector = ExecutableSecurityInspector()

        let report = await inspector.report(executablePath: "/bin/ls", targetPath: "/private/etc/hosts")

        let executable = try XCTUnwrap(report.executable)
        XCTAssertEqual(executable.sandbox, .notSandboxed)
        XCTAssertEqual(executable.permissions.owner, "root")
        XCTAssertFalse(executable.permissions.isSetUserID)
        XCTAssertNotNil(report.targetPermissions)

        let missing = await inspector.report(executablePath: "/nonexistent/binary", targetPath: "/nonexistent/file")
        XCTAssertNil(missing.executable)
        XCTAssertNil(missing.targetPermissions)
    }

    func testReportFindsEntitlementsOfSandboxedSystemApp() async throws {
        // Calculator ships sandboxed on every supported macOS.
        let path = "/System/Applications/Calculator.app/Contents/MacOS/Calculator"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))

        let inspector = ExecutableSecurityInspector()
        let report = await inspector.report(executablePath: path, targetPath: nil)

        XCTAssertEqual(report.executable?.sandbox, .sandboxed)
        XCTAssertEqual(
            report.executable?.entitlements.contains { $0.key == "com.apple.security.app-sandbox" },
            true
        )
    }
}
