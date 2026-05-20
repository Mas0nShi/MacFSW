import Foundation
import MacFSWAnalysis

@MainActor
final class AppPreferencesStore: ObservableObject {
    @Published var llmSettings: MacFSWLLMSettings {
        didSet {
            persistLLMSettings()
        }
    }

    @Published var defaultStartupPage: MacFSWNavigationPage {
        didSet {
            defaults.set(defaultStartupPage.rawValue, forKey: Self.defaultStartupPageKey)
        }
    }

    @Published var defaultIncludeExitedProcesses: Bool {
        didSet {
            defaults.set(defaultIncludeExitedProcesses, forKey: Self.includeExitedProcessesDefaultKey)
        }
    }

    var onError: ((Error) -> Void)?

    private let settingsStore: MacFSWSettingsStore
    private let defaults: UserDefaults
    private var isLoading = false
    private static let includeExitedProcessesDefaultKey = "MacFSW.IncludeExitedProcesses.Default"
    private static let defaultStartupPageKey = "MacFSW.DefaultStartupPage"

    init(settingsStore: MacFSWSettingsStore, defaults: UserDefaults = .standard) {
        self.settingsStore = settingsStore
        self.defaults = defaults
        self.llmSettings = MacFSWLLMSettings()
        self.defaultStartupPage = .monitor
        self.defaultIncludeExitedProcesses = true
        load()
    }

    private func load() {
        isLoading = true
        llmSettings = settingsStore.loadLLMSettings()
        defaultIncludeExitedProcesses = defaults.object(forKey: Self.includeExitedProcessesDefaultKey) as? Bool ?? true
        if let rawPage = defaults.string(forKey: Self.defaultStartupPageKey),
           let page = MacFSWNavigationPage(rawValue: rawPage) {
            defaultStartupPage = page
        }
        isLoading = false
    }

    private func persistLLMSettings() {
        guard !isLoading else {
            return
        }
        do {
            try settingsStore.saveLLMSettings(llmSettings)
        } catch {
            onError?(error)
        }
    }
}
