import AppKit
import MacFSWAnalysis
import MacFSWCore

@MainActor
protocol SystemExtensionInstalling: AnyObject {
    var onStateChange: ((MacFSWSystemExtensionInstallState, String) -> Void)? { get set }

    func activate()
    func checkInstalledVersion()
    func resetSubmission()
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
    var makeTemporaryEventStore: (MacFSWResearchSession) throws -> MacFSWSQLiteEventStore
    var cleanupStaleTemporaryStores: () throws -> Void
    var makeOpenPanel: () -> NSOpenPanel
    var makeSavePanel: () -> NSSavePanel

    static var live: MacFSWAppEnvironment {
        let xpcServiceName = Bundle.main.object(forInfoDictionaryKey: "MacFSWXPCServiceName") as? String
        let serviceName = xpcServiceName.flatMap { $0.isEmpty ? nil : $0 } ?? MacFSWXPCDefaults.serviceName
        return MacFSWAppEnvironment(
            appVersion: bundleVersion(),
            captureClient: MacFSWXPCCaptureClient(serviceName: serviceName),
            extensionInstaller: SystemExtensionInstaller.shared,
            settingsStore: .shared,
            llmClient: MacFSWLLMClient(),
            makeTemporaryEventStore: { try MacFSWSQLiteEventStore.temporary(session: $0) },
            cleanupStaleTemporaryStores: { try MacFSWSQLiteEventStore.cleanupStaleTemporaryStores() },
            makeOpenPanel: NSOpenPanel.init,
            makeSavePanel: NSSavePanel.init
        )
    }

    private static func bundleVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "development"
    }
}
