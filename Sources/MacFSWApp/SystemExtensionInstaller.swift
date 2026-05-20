import AppKit
import Foundation
import Security
import SystemExtensions

enum MacFSWSystemExtensionInstallState: String {
    case unknown
    case notReady
    case activating
    case needsApproval
    case ready
    case failed

    var title: String {
        switch self {
        case .unknown:
            "Checking"
        case .notReady:
            "Not Installed"
        case .activating:
            "Activating"
        case .needsApproval:
            "Needs Approval"
        case .ready:
            "Ready"
        case .failed:
            "Failed"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown:
            "circle.dotted"
        case .notReady:
            "puzzlepiece.extension"
        case .activating:
            "arrow.triangle.2.circlepath"
        case .needsApproval:
            "hand.raised"
        case .ready:
            "checkmark.seal.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }
}

private struct InstalledExtensionPropertiesSnapshot: Sendable {
    let bundleShortVersion: String
    let bundleVersion: String
    let isEnabled: Bool
    let isUninstalling: Bool
}

@MainActor
final class SystemExtensionInstaller: NSObject {
    static let shared = SystemExtensionInstaller()

    var onStateChange: ((MacFSWSystemExtensionInstallState, String) -> Void)?

    private var submitted = false
    private var currentRequest: OSSystemExtensionRequest?
    private var currentRequestKind: RequestKind?
    private let installEntitlement = "com.apple.developer.system-extension.install"

    private enum RequestKind {
        case activation
        case properties
    }

    private var extensionIdentifier: String {
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "MacFSWSystemExtensionBundleIdentifier") as? String,
           !identifier.isEmpty {
            return identifier
        }
        return "com.mas0n.MacFSW.EndpointExtension"
    }

    func activate() {
        guard isRunningFromAppBundle else {
            publish(
                .failed,
                "MacFSW is not running from a signed .app bundle. Build and open MacFSW.app with Scripts/package-dev-app.sh before enabling the System Extension."
            )
            return
        }

        guard isRunningFromApplicationsDirectory else {
            publish(
                .failed,
                "Move MacFSW.app to /Applications before enabling the System Extension. macOS rejects System Extension activation from other locations unless developer mode is explicitly enabled."
            )
            return
        }

        guard hasSystemExtensionInstallEntitlement() else {
            publish(
                .failed,
                "MacFSW.app is missing \(installEntitlement). Rebuild the signed app bundle and verify host app entitlements before enabling the System Extension."
            )
            return
        }

        guard !submitted else {
            publish(.activating, "System Extension activation is already in progress.")
            return
        }

        submitted = true
        publish(.activating, "Requesting macOS to activate the MacFSW Endpoint Extension.")

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        currentRequest = request
        currentRequestKind = .activation
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func checkInstalledVersion() {
        guard isRunningFromAppBundle else {
            return
        }

        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        currentRequest = request
        currentRequestKind = .properties
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func resetSubmission() {
        submitted = false
        currentRequest = nil
        currentRequestKind = nil
    }

    func openLoginItemsSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.settings.LoginItems",
        ]

        openFirstAvailableSettingsURL(urls)
    }

    func openFullDiskAccessSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ]

        openFirstAvailableSettingsURL(urls)
    }

    private func openFirstAvailableSettingsURL(_ urls: [String]) {
        for value in urls {
            guard let url = URL(string: value) else {
                continue
            }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func publish(_ state: MacFSWSystemExtensionInstallState, _ message: String) {
        onStateChange?(state, message)
    }

    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private var isRunningFromApplicationsDirectory: Bool {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let applicationsPath = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .standardizedFileURL
            .path
        return bundlePath.hasPrefix(applicationsPath + "/")
    }

    private func hasSystemExtensionInstallEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else {
            return false
        }
        let value = SecTaskCopyValueForEntitlement(task, installEntitlement as CFString, nil)
        return (value as? Bool) == true
    }
}

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            guard currentRequestKind == .activation else {
                currentRequest = nil
                currentRequestKind = nil
                return
            }
            submitted = false
            currentRequest = nil
            currentRequestKind = nil
            publish(.ready, "System Extension activation finished. Checking capture service readiness.")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            guard currentRequestKind == .activation else {
                currentRequest = nil
                currentRequestKind = nil
                return
            }
            submitted = false
            currentRequest = nil
            currentRequestKind = nil
            publish(.failed, userFacingMessage(error))
        }
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            publish(.needsApproval, "macOS requires approval in System Settings > General > Login Items & Extensions before MacFSW can install or update the Endpoint Extension.")
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        let snapshots = properties.map {
            InstalledExtensionPropertiesSnapshot(
                bundleShortVersion: $0.bundleShortVersion,
                bundleVersion: $0.bundleVersion,
                isEnabled: $0.isEnabled,
                isUninstalling: $0.isUninstalling
            )
        }
        Task { @MainActor in
            handleInstalledProperties(snapshots)
        }
    }

    private func handleInstalledProperties(_ properties: [InstalledExtensionPropertiesSnapshot]) {
        currentRequest = nil
        currentRequestKind = nil

        guard let bundledVersion = bundledExtensionVersion else {
            return
        }

        let activeProperties = properties.filter { $0.isEnabled && !$0.isUninstalling }
        guard !activeProperties.isEmpty else {
            publish(.notReady, "MacFSW Endpoint Extension is not installed or enabled.")
            return
        }

        let hasBundledVersion = activeProperties.contains {
            $0.bundleShortVersion == bundledVersion.shortVersion
                && $0.bundleVersion == bundledVersion.buildVersion
        }

        if !hasBundledVersion {
            let installed = activeProperties
                .map { "\($0.bundleShortVersion)/\($0.bundleVersion)" }
                .joined(separator: ", ")
            publish(
                .activating,
                "Updating Endpoint Extension from \(installed) to \(bundledVersion.shortVersion)/\(bundledVersion.buildVersion)."
            )
            submitted = false
            activate()
        }
    }

    private var bundledExtensionVersion: (shortVersion: String, buildVersion: String)? {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(extensionIdentifier).systemextension")
            .appendingPathComponent("Contents/Info.plist")

        guard
            let dictionary = NSDictionary(contentsOf: extensionURL),
            let shortVersion = dictionary["CFBundleShortVersionString"] as? String,
            let buildVersion = dictionary["CFBundleVersion"] as? String
        else {
            return nil
        }

        return (shortVersion, buildVersion)
    }
}

private func userFacingMessage(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    return String(describing: error)
}
