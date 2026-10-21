import Foundation
import Observation
import MacFSWAnalysis

@MainActor
@Observable
final class AppPreferencesStore {
    /// Everything but the API key; see `apiKey`.
    var llmSettings: MacFSWLLMSettings {
        didSet {
            persistLLMSettings()
        }
    }

    /// Read from the keychain on first use rather than at launch, so the app
    /// touches the keychain only when analysis actually needs the key.
    var apiKey: String {
        get {
            access(keyPath: \.apiKey)
            if let loadedAPIKey {
                return loadedAPIKey
            }
            let key = settingsStore.loadAPIKey()
            loadedAPIKey = key
            return key
        }
        set {
            guard newValue != apiKey else {
                return
            }
            withMutation(keyPath: \.apiKey) {
                loadedAPIKey = newValue
            }
            do {
                try settingsStore.saveAPIKey(newValue)
            } catch {
                onError?(error)
            }
        }
    }

    /// The settings an LLM request needs, key included.
    var resolvedLLMSettings: MacFSWLLMSettings {
        var settings = llmSettings
        settings.apiKey = apiKey
        return settings
    }

    var defaultStartupPage: MacFSWNavigationPage {
        didSet {
            defaults.set(defaultStartupPage.rawValue, forKey: Self.defaultStartupPageKey)
        }
    }

    var defaultIncludeExitedProcesses: Bool {
        didSet {
            defaults.set(defaultIncludeExitedProcesses, forKey: Self.includeExitedProcessesDefaultKey)
        }
    }

    @ObservationIgnored
    var onError: ((Error) -> Void)?

    private let settingsStore: MacFSWSettingsStore
    private let defaults: UserDefaults
    @ObservationIgnored
    private var isLoading = false
    @ObservationIgnored
    private var loadedAPIKey: String?
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
