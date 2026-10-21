import AppKit
import MacFSWAnalysis
import MacFSWCore

@MainActor
protocol SystemExtensionInstalling: AnyObject {
    var onStateChange: ((MacFSWSystemExtensionInstallState, String) -> Void)? { get set }
    /// An older activated extension is being replaced: (installed, bundled).
    var onUpdateStarted: ((String, String) -> Void)? { get set }

    func activate()
    func checkInstalledVersion()
    func openLoginItemsSettings()
    func openFullDiskAccessSettings()
}

extension SystemExtensionInstaller: SystemExtensionInstalling {}

@MainActor
struct MacFSWAppEnvironment {
    var appVersion: String
    var captureClient: any MacFSWCaptureClient
    var extensionInstaller: any SystemExtensionInstalling
    var settingsStore: MacFSWSettingsStore
    var llmClient: MacFSWLLMClient

    static var live: MacFSWAppEnvironment {
        MacFSWAppEnvironment(
            appVersion: Bundle.main.macfswVersion,
            captureClient: MacFSWXPCCaptureClient(serviceName: Bundle.main.macfswXPCServiceName),
            extensionInstaller: SystemExtensionInstaller.shared,
            settingsStore: .shared,
            llmClient: MacFSWLLMClient()
        )
    }
}
