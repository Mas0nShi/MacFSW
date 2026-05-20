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

    public init(
        endpoint: MacFSWLLMEndpoint = .responses,
        baseURL: String = "https://api.openai.com",
        apiKey: String = "",
        model: String = "gpt-4.1",
        maxEvents: Int = 500,
        tokenBudget: Int = 12_000,
        timeoutSeconds: Int = 60,
        streamResponses: Bool = true
    ) {
        self.endpoint = endpoint
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxEvents = max(1, maxEvents)
        self.tokenBudget = max(1, tokenBudget)
        self.timeoutSeconds = max(1, timeoutSeconds)
        self.streamResponses = streamResponses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            endpoint: try container.decodeIfPresent(MacFSWLLMEndpoint.self, forKey: .endpoint) ?? .responses,
            baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com",
            apiKey: "",
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-4.1",
            maxEvents: try container.decodeIfPresent(Int.self, forKey: .maxEvents) ?? 500,
            tokenBudget: try container.decodeIfPresent(Int.self, forKey: .tokenBudget) ?? 12_000,
            timeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60,
            streamResponses: try container.decodeIfPresent(Bool.self, forKey: .streamResponses) ?? true
        )
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint
        case baseURL
        case model
        case maxEvents
        case tokenBudget
        case timeoutSeconds
        case streamResponses
    }
}

public final class MacFSWSettingsStore: @unchecked Sendable {
    public static let shared = MacFSWSettingsStore()

    private let defaults: UserDefaults
    private let settingsKey: String
    private let keychainService: String
    private let keychainAccount: String

    public init(
        defaults: UserDefaults = .standard,
        settingsKey: String = "MacFSW.LLMSettings.v1",
        keychainService: String = "com.macfsw.llm",
        keychainAccount: String = "default"
    ) {
        self.defaults = defaults
        self.settingsKey = settingsKey
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    public func loadLLMSettings() -> MacFSWLLMSettings {
        let decoded: MacFSWLLMSettings
        if let data = defaults.data(forKey: settingsKey),
           let settings = try? JSONDecoder().decode(MacFSWLLMSettings.self, from: data) {
            decoded = settings
        } else {
            decoded = MacFSWLLMSettings()
        }

        var settings = decoded
        settings.apiKey = (try? MacFSWKeychain.read(service: keychainService, account: keychainAccount)) ?? ""
        return settings
    }

    public func saveLLMSettings(_ settings: MacFSWLLMSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: settingsKey)
        try MacFSWKeychain.save(settings.apiKey, service: keychainService, account: keychainAccount)
    }
}
