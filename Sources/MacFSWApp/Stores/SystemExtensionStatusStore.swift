import Foundation
import Observation
import MacFSWCore

@MainActor
@Observable
final class SystemExtensionStatusStore {
    var installState: MacFSWSystemExtensionInstallState = .unknown
    var installMessage = "Checking System Extension readiness."
    /// What the running extension reported; nil until a health check
    /// succeeds, and for extensions too old to report it.
    private(set) var runningVersion: MacFSWComponentVersion?
    /// The extension packaged in this app — what activation installs.
    let bundledVersion = Bundle.main.bundledEndpointExtensionVersion
    /// Set when this launch replaced an older extension, so the update
    /// stays visible after the status settles on Ready.
    private(set) var completedUpdate: (from: String, to: String)?
    @ObservationIgnored
    private var pendingUpdate: (from: String, to: String)?

    /// The running extension is not the one this app bundles: health
    /// checks may pass while newer capabilities are missing.
    var isRunningOutdatedExtension: Bool {
        guard installState == .ready, let bundledVersion else {
            return false
        }
        return runningVersion != bundledVersion
    }

    @ObservationIgnored
    var onErrorMessage: ((String) -> Void)?
    @ObservationIgnored
    var onReady: (() -> Void)?

    private let installer: any SystemExtensionInstalling

    init(installer: any SystemExtensionInstalling) {
        self.installer = installer
        self.installer.onStateChange = { [weak self] state, message in
            guard let self else {
                return
            }
            installState = state
            installMessage = message
            switch state {
            case .failed:
                pendingUpdate = nil
                onErrorMessage?(message)
            case .ready:
                if let pendingUpdate {
                    completedUpdate = pendingUpdate
                    self.pendingUpdate = nil
                }
                onReady?()
            default:
                break
            }
        }
        self.installer.onUpdateStarted = { [weak self] installed, bundled in
            self?.pendingUpdate = (installed, bundled)
        }
    }

    func activate() {
        installer.activate()
    }

    func openLoginItemsSettings() {
        installer.openLoginItemsSettings()
    }

    func openFullDiskAccessSettings() {
        installer.openFullDiskAccessSettings()
    }

    func checkAgain() {
        installer.resetSubmission()
    }

    func applyHealth(_ health: MacFSWCaptureHealth) {
        if health.fullDiskAccessHint {
            installState = .failed
            installMessage = health.message
            return
        }

        runningVersion = health.extensionVersion
        installState = .ready
        installMessage = health.endpointSecurityAuthorized
            ? "MacFSW Endpoint Extension is reachable and has Endpoint Security permission."
            : "MacFSW Endpoint Extension is reachable."
        installer.checkInstalledVersion()
    }

    func applyHealthRefreshFailure(message: String) {
        if installState != .activating && installState != .needsApproval {
            installState = .notReady
            installMessage = "MacFSW Endpoint Extension is not installed, not approved, or not reachable."
            installer.checkInstalledVersion()
        }
    }

    func applyXPCFailure(message: String) {
        installer.resetSubmission()
        installState = .notReady
        installMessage = "The installed Endpoint Extension is not accepting capture streams. It may be out of date; enable the System Extension again to install the bundled version."
    }

    func applyFullDiskAccessFailure(message: String) {
        installState = .failed
        installMessage = message
    }
}
