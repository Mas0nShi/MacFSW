import Foundation
import MacFSWCore

@MainActor
final class SystemExtensionStatusStore: ObservableObject {
    @Published var installState: MacFSWSystemExtensionInstallState = .unknown
    @Published var installMessage = "Checking System Extension readiness."

    var onErrorMessage: ((String) -> Void)?
    var onReady: (() -> Void)?

    private let installer: any SystemExtensionInstalling

    init(installer: any SystemExtensionInstalling) {
        self.installer = installer
        self.installer.onStateChange = { [weak self] state, message in
            self?.installState = state
            self?.installMessage = message
            if state == .failed {
                self?.onErrorMessage?(message)
            }
            if state == .ready {
                self?.onReady?()
            }
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
