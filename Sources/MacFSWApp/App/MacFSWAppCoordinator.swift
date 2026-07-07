import AppKit
import Combine
import Darwin
import MacFSWAnalysis
import MacFSWCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MacFSWAppCoordinator: ObservableObject {
    @Published var selectedPage: MacFSWNavigationPage = .monitor
    @Published var errorMessage: String?

    let preferencesStore: AppPreferencesStore
    let processSidebarStore: ProcessSidebarStore
    let systemExtensionStatusStore: SystemExtensionStatusStore
    let analysisStore: AnalysisStore
    let sessionStore: SessionStore
    let captureStore: CaptureStore
    let monitorStore: MonitorStore
    let queryHistoryStore: QueryHistoryStore
    let logStore: AppLogStore

    let environment: MacFSWAppEnvironment
    var storeCancellables: Set<AnyCancellable> = []
    var pendingCaptureStats: MacFSWCaptureStats?

    init(environment: MacFSWAppEnvironment = .live) {
        self.environment = environment
        self.preferencesStore = AppPreferencesStore(settingsStore: environment.settingsStore)
        self.processSidebarStore = ProcessSidebarStore(
            includeExitedProcesses: preferencesStore.defaultIncludeExitedProcesses
        )
        self.systemExtensionStatusStore = SystemExtensionStatusStore(installer: environment.extensionInstaller)
        self.analysisStore = AnalysisStore(llmClient: environment.llmClient)
        self.captureStore = CaptureStore(client: environment.captureClient)
        self.monitorStore = MonitorStore()
        self.queryHistoryStore = QueryHistoryStore()
        self.logStore = AppLogStore()
        let initialSession = MacFSWResearchSession(
            name: "Untitled Research Session",
            targetDescription: "Focused file-system mutation capture",
            metadata: MacFSWSessionMetadata(appVersion: environment.appVersion)
        )
        self.sessionStore = SessionStore(environment: environment, initialSession: initialSession)
        self.selectedPage = preferencesStore.defaultStartupPage
        observeStores()
        logStore.record(.info, "App coordinator initialized.", category: "App")
    }

    func makeSessionMetadata(appVersion: String? = nil, source: MacFSWSessionSource = .live) -> MacFSWSessionMetadata {
        MacFSWSessionMetadata(appVersion: appVersion ?? environment.appVersion, source: source)
    }
}
