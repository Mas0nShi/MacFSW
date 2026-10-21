import Security
import XCTest
@testable import MacFSWSystemExtension

final class XPCClientPolicyTests: XCTestCase {
    func testRequirementCompilesAndAdmitsHostAndCLI() {
        let policy = XPCClientPolicy()
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(policy.requirement as CFString, SecCSFlags(), &requirement)

        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(requirement)
        XCTAssertTrue(policy.requirement.contains(#"identifier "com.mas0n.MacFSW" and"#))
        XCTAssertTrue(policy.requirement.contains(#"identifier "com.mas0n.MacFSW.cli" and"#))
        XCTAssertTrue(policy.requirement.contains("com.apple.developer.system-extension.install"))
        XCTAssertEqual(policy.requirement.components(separatedBy: "UYF535Y9QZ").count - 1, 2)
    }
}
