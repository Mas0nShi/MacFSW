import Foundation

public enum MacFSWLLMEndpoint: String, CaseIterable, Codable, Identifiable, Sendable {
    case responses = "/v1/responses"
    case chatCompletions = "/v1/chat/completions"
    case completions = "/v1/completions"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .responses:
            "Responses"
        case .chatCompletions:
            "Chat"
        case .completions:
            "Completions"
        }
    }
}

public struct MacFSWLLMSettings: Codable, Equatable, Sendable {
    public var endpoint: MacFSWLLMEndpoint
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var maxEvents: Int
    public var tokenBudget: Int
    public var timeoutSeconds: Int
    public var streamResponses: Bool
    public var outputLanguage: MacFSWAnalysisOutputLanguage
    /// Character budget for the {{event_samples}} block in the prompt.
    /// Enforced in characters (deterministic across arbitrary tokenizers);
    /// the settings UI captions it with a chars/4 token estimate.
    public var promptEventCharacterBudget: Int

    public init(
        endpoint: MacFSWLLMEndpoint = .responses,
        baseURL: String = "https://api.openai.com",
        apiKey: String = "",
        model: String = "gpt-4.1",
        maxEvents: Int = 500,
        tokenBudget: Int = 12_000,
        timeoutSeconds: Int = 60,
        streamResponses: Bool = true,
        outputLanguage: MacFSWAnalysisOutputLanguage = .english,
        promptEventCharacterBudget: Int = 120_000
    ) {
        self.endpoint = endpoint
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxEvents = maxEvents
        self.tokenBudget = tokenBudget
        self.timeoutSeconds = timeoutSeconds
        self.streamResponses = streamResponses
        self.outputLanguage = outputLanguage
        self.promptEventCharacterBudget = promptEventCharacterBudget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let language = try container.decodeIfPresent(String.self, forKey: .outputLanguage)
            .flatMap(MacFSWAnalysisOutputLanguage.init(rawValue:)) ?? .english
        self.init(
            endpoint: try container.decodeIfPresent(MacFSWLLMEndpoint.self, forKey: .endpoint) ?? .responses,
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com",
            apiKey: "",
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-4.1",
            maxEvents: try container.decodeIfPresent(Int.self, forKey: .maxEvents) ?? 500,
            tokenBudget: try container.decodeIfPresent(Int.self, forKey: .tokenBudget) ?? 12_000,
            timeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60,
            streamResponses: try container.decodeIfPresent(Bool.self, forKey: .streamResponses) ?? true,
            outputLanguage: language,
            promptEventCharacterBudget: try container.decodeIfPresent(Int.self, forKey: .promptEventCharacterBudget) ?? 120_000
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(model, forKey: .model)
        try container.encode(maxEvents, forKey: .maxEvents)
        try container.encode(tokenBudget, forKey: .tokenBudget)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(streamResponses, forKey: .streamResponses)
        try container.encode(outputLanguage.rawValue, forKey: .outputLanguage)
        try container.encode(promptEventCharacterBudget, forKey: .promptEventCharacterBudget)
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case baseURL
        case model
        case maxEvents
        case tokenBudget
        case timeoutSeconds
        case streamResponses
        case outputLanguage
        case promptEventCharacterBudget
    }
}

/// Persisted prompt-template state: custom templates plus the id of the
/// currently-selected template (built-in or custom). Selection is stored
/// separately from the templates so switching between built-ins is a single
/// small write.
public struct MacFSWAnalysisPromptTemplateState: Codable, Equatable, Sendable {
    public var customTemplates: [MacFSWAnalysisPromptTemplate]
    public var selectedTemplateID: UUID?

    public init(customTemplates: [MacFSWAnalysisPromptTemplate] = [], selectedTemplateID: UUID? = nil) {
        self.customTemplates = customTemplates
        self.selectedTemplateID = selectedTemplateID
    }
}

public final class MacFSWSettingsStore: @unchecked Sendable {
    public static let shared = MacFSWSettingsStore()

    private let defaults: UserDefaults
    private let settingsKey: String
    private let promptTemplatesKey: String
    private let keychainService: String
    private let keychainAccount: String

    public init(
        defaults: UserDefaults = .standard,
        settingsKey: String = "MacFSW.LLMSettings.v1",
        promptTemplatesKey: String = "MacFSW.AnalysisPromptTemplates.v1",
        keychainService: String = "com.macfsw.llm",
        keychainAccount: String = "default"
    ) {
        self.defaults = defaults
        self.settingsKey = settingsKey
        self.promptTemplatesKey = promptTemplatesKey
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    /// Settings without the API key, which lives in the keychain and is
    /// read only when needed (see `loadAPIKey()`).
    public func loadLLMSettings() -> MacFSWLLMSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(MacFSWLLMSettings.self, from: data) else {
            return MacFSWLLMSettings()
        }
        return settings
    }

    public func saveLLMSettings(_ settings: MacFSWLLMSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: settingsKey)
    }

    /// Reads the API key from the data-protection keychain, moving a key
    /// left in the legacy keychain by older builds on first use (that one
    /// read may still prompt). Builds without the keychain entitlement —
    /// unsigned development runs — get no key rather than a prompt.
    public func loadAPIKey() -> String {
        do {
            if let key = try MacFSWKeychain.read(service: keychainService, account: keychainAccount) {
                return key
            }
        } catch {
            return ""
        }
        guard let legacy = try? MacFSWKeychain.read(service: keychainService, account: keychainAccount, in: .legacyFile),
              !legacy.isEmpty else {
            return ""
        }
        if (try? MacFSWKeychain.save(legacy, service: keychainService, account: keychainAccount)) != nil {
            try? MacFSWKeychain.delete(service: keychainService, account: keychainAccount, in: .legacyFile)
        }
        return legacy
    }

    public func saveAPIKey(_ key: String) throws {
        try MacFSWKeychain.save(key, service: keychainService, account: keychainAccount)
    }

    public func loadPromptTemplateState() -> MacFSWAnalysisPromptTemplateState {
        guard let data = defaults.data(forKey: promptTemplatesKey),
              let state = try? JSONDecoder().decode(MacFSWAnalysisPromptTemplateState.self, from: data) else {
            return MacFSWAnalysisPromptTemplateState()
        }
        return state
    }

    public func savePromptTemplateState(_ state: MacFSWAnalysisPromptTemplateState) throws {
        let data = try JSONEncoder().encode(state)
        defaults.set(data, forKey: promptTemplatesKey)
    }
}
