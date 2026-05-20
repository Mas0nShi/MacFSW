import Foundation
import Security
import XCTest
@testable import MacFSWSystemExtension

final class XPCConnectionAuthorizerTests: XCTestCase {
    func testHostCodeSigningRequirementCompiles() {
        let policy = XPCConnectionAuthorizationPolicy()
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            policy.codeSigningRequirementText as CFString,
            SecCSFlags(),
            &requirement
        )

        XCTAssertEqual(status, errSecSuccess)
        XCTAssertNotNil(requirement)
        XCTAssertTrue(policy.codeSigningRequirementText.contains("com.mas0n.MacFSW"))
        XCTAssertTrue(policy.codeSigningRequirementText.contains("UYF535Y9QZ"))
        XCTAssertTrue(policy.codeSigningRequirementText.contains("com.apple.developer.system-extension.install"))
    }
}
