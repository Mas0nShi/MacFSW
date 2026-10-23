import Foundation

/// Report output language. Raw values are stable persistence identifiers —
/// never localized display names.
public enum MacFSWAnalysisOutputLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case english
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case russian = "ru"
    case portuguese = "pt"

    public var id: String { rawValue }

    public var pickerTitle: String {
        switch self {
        case .english:
            return "English"
        case .system:
            return "Follow System"
        case .simplifiedChinese:
            return "Simplified Chinese (简体中文)"
        case .traditionalChinese:
            return "Traditional Chinese (繁體中文)"
        case .japanese:
            return "Japanese (日本語)"
        case .korean:
            return "Korean (한국어)"
        case .french:
            return "French (Français)"
        case .german:
            return "German (Deutsch)"
        case .spanish:
            return "Spanish (Español)"
        case .russian:
            return "Russian (Русский)"
        case .portuguese:
            return "Portuguese (Português)"
        }
    }

    /// English language name injected into prompts (models follow English
    /// language names most reliably). `.system` resolves through the given
    /// locale — passed in by the caller so this module reads no global state.
    public func promptName(resolvingSystemWith locale: Locale) -> String {
        switch self {
        case .english:
            return "English"
        case .system:
            let english = Locale(identifier: "en_US")
            guard let code = locale.language.languageCode?.identifier,
                  let name = english.localizedString(forLanguageCode: code) else {
                return "English"
            }
            return name
        case .simplifiedChinese:
            return "Simplified Chinese"
        case .traditionalChinese:
            return "Traditional Chinese"
        case .japanese:
            return "Japanese"
        case .korean:
            return "Korean"
        case .french:
            return "French"
        case .german:
            return "German"
        case .spanish:
            return "Spanish"
        case .russian:
            return "Russian"
        case .portuguese:
            return "Portuguese"
        }
    }
}
