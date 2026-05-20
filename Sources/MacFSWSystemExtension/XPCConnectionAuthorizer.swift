import Foundation
import Security

public struct XPCConnectionAuthorizationPolicy: Sendable {
    public var expectedBundleIdentifier: String
    public var expectedTeamIdentifier: String
    public var requiredEntitlement: String

    public init(
        expectedBundleIdentifier: String = "com.mas0n.MacFSW",
        expectedTeamIdentifier: String = "UYF535Y9QZ",
        requiredEntitlement: String = "com.apple.developer.system-extension.install"
    ) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.requiredEntitlement = requiredEntitlement
    }

    public var codeSigningRequirementText: String {
        """
        identifier "\(expectedBundleIdentifier)" and anchor apple generic and certificate leaf[subject.OU] = "\(expectedTeamIdentifier)" and entitlement["\(requiredEntitlement)"] exists
        """
    }
}

public enum XPCConnectionAuthorizationError: Error, LocalizedError, Sendable {
    case missingProcessIdentifier
    case requirementCreationFailed(OSStatus)
    case codeLookupFailed(OSStatus)
    case codeValidationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .missingProcessIdentifier:
            "The XPC connection did not expose a valid client process identifier."
        case .requirementCreationFailed(let status):
            "Unable to create code-signing requirement: \(status)."
        case .codeLookupFailed(let status):
            "Unable to resolve client code identity: \(status)."
        case .codeValidationFailed(let status):
            "Client code signature does not satisfy the MacFSW host requirement: \(status)."
        }
    }
}

public final class XPCConnectionAuthorizer: Sendable {
    private let policy: XPCConnectionAuthorizationPolicy

    public init(policy: XPCConnectionAuthorizationPolicy = XPCConnectionAuthorizationPolicy()) {
        self.policy = policy
    }

    public func authorize(_ connection: NSXPCConnection) -> Result<Void, XPCConnectionAuthorizationError> {
        do {
            try validate(connection)
            return .success(())
        } catch let error as XPCConnectionAuthorizationError {
            return .failure(error)
        } catch {
            return .failure(.codeValidationFailed(errSecInternalComponent))
        }
    }

    private func validate(_ connection: NSXPCConnection) throws {
        let pid = connection.processIdentifier
        guard pid > 0 else {
            throw XPCConnectionAuthorizationError.missingProcessIdentifier
        }

        let requirement = try makeRequirement()
        let code = try copyCode(forPID: pid)
        let status = SecCodeCheckValidity(code, SecCSFlags(), requirement)
        guard status == errSecSuccess else {
            throw XPCConnectionAuthorizationError.codeValidationFailed(status)
        }
    }

    private func makeRequirement() throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(policy.codeSigningRequirementText as CFString, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            throw XPCConnectionAuthorizationError.requirementCreationFailed(status)
        }
        return requirement
    }

    private func copyCode(forPID pid: pid_t) throws -> SecCode {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: pid)
        ] as CFDictionary

        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            throw XPCConnectionAuthorizationError.codeLookupFailed(status)
        }
        return code
    }
}
