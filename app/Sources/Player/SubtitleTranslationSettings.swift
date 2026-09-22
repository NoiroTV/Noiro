#if os(iOS) || os(tvOS) || os(macOS)
import Foundation

/// Gemini AI subtitle translation settings — extends Noiro's `PlaybackSettings` (in TrackPreferences.swift)
/// with the provider/mode/target prefs. All `@AppStorage`-backed so they persist + sync like the other
/// playback prefs. The Gemini API key lives separately in `ApiKeys.gemini` (Keychain).
extension PlaybackSettings {

    // MARK: Provider

    /// Which translation backend to use (Off = the feature is fully disabled; Gemini = the only backend).
    enum SubtitleTranslationProvider: String, CaseIterable, Sendable {
        case off
        case gemini
        var label: String {
            switch self {
            case .off: return "Off"
            case .gemini: return "Gemini"
            }
        }
    }

    /// When to translate: `whenNeeded` only translates tracks not already in an accepted language;
    /// `always` translates every selected track regardless of its language.
    enum SubtitleTranslationMode: String, CaseIterable, Sendable {
        case whenNeeded
        case always
        var label: String {
            switch self {
            case .whenNeeded: return "When needed"
            case .always: return "Always"
            }
        }
    }

    /// How long an on-device translated subtitle track remains available after its most recent use.
    enum SubtitleTranslationCachePeriod: String, CaseIterable, Sendable {
        case days7 = "7"
        case days14 = "14"
        case days30 = "30"
        case days60 = "60"
        case days90 = "90"
        case unlimited

        var label: String {
            switch self {
            case .days7: return "7 days"
            case .days14: return "14 days"
            case .days30: return "30 days"
            case .days60: return "60 days"
            case .days90: return "90 days"
            case .unlimited: return "Unlimited"
            }
        }

        var retentionInterval: TimeInterval? {
            guard let days = Int(rawValue) else { return nil }
            return TimeInterval(days * 24 * 60 * 60)
        }
    }

    // MARK: Keys

    enum SubtitleTranslationKey {
        static let provider = "noiro.subtitleTranslation.provider"
        static let targetLanguage = "noiro.subtitleTranslation.targetLanguage"
        static let mode = "noiro.subtitleTranslation.mode"
        static let cachePeriod = "noiro.subtitleTranslation.cachePeriod"
    }

    // MARK: Values

    /// The active translation provider. `.off` by default — translation is opt-in.
    static var subtitleTranslationProvider: SubtitleTranslationProvider {
        let raw = UserDefaults.standard.string(forKey: SubtitleTranslationKey.provider) ?? SubtitleTranslationProvider.off.rawValue
        return SubtitleTranslationProvider(rawValue: raw) ?? .off
    }
    static func setSubtitleTranslationProvider(_ value: SubtitleTranslationProvider) {
        UserDefaults.standard.set(value.rawValue, forKey: SubtitleTranslationKey.provider)
    }

    /// The ISO code to translate INTO ("en", "hr", ...). Default "en".
    static var subtitleTranslationTargetLanguage: String {
        let raw = UserDefaults.standard.string(forKey: SubtitleTranslationKey.targetLanguage) ?? "en"
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "en" : raw
    }
    static func setSubtitleTranslationTargetLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: SubtitleTranslationKey.targetLanguage)
    }

    static var subtitleTranslationMode: SubtitleTranslationMode {
        let raw = UserDefaults.standard.string(forKey: SubtitleTranslationKey.mode) ?? SubtitleTranslationMode.whenNeeded.rawValue
        return SubtitleTranslationMode(rawValue: raw) ?? .whenNeeded
    }
    static func setSubtitleTranslationMode(_ value: SubtitleTranslationMode) {
        UserDefaults.standard.set(value.rawValue, forKey: SubtitleTranslationKey.mode)
    }

    /// Defaults to 30 days for existing installs that predate the setting.
    static var subtitleTranslationCachePeriod: SubtitleTranslationCachePeriod {
        let raw = UserDefaults.standard.string(forKey: SubtitleTranslationKey.cachePeriod)
            ?? SubtitleTranslationCachePeriod.days30.rawValue
        return SubtitleTranslationCachePeriod(rawValue: raw) ?? .days30
    }

    /// Convenience: translation is "on" only when a provider is set AND a Gemini key exists.
    static var isSubtitleTranslationEnabled: Bool {
        subtitleTranslationProvider == .gemini && (ApiKeys.geminiKey() != nil)
    }
}

// MARK: - Selectable target languages

/// The languages a user can pick as the translation target. ISO 639-1 codes (matches the prompt's
/// `targetLanguageName` map in SubtitleTranslationService). English first (the most common target).
enum SubtitleTranslationLanguage: String, CaseIterable, Identifiable {
    case english = "en", spanish = "es", french = "fr", german = "de", italian = "it"
    case portuguese = "pt", russian = "ru", japanese = "ja", korean = "ko", chinese = "zh"
    case arabic = "ar", hindi = "hi", dutch = "nl", polish = "pl", swedish = "sv"
    case croatian = "hr", serbian = "sr", bosnian = "bs"
    case albanian = "sq", bulgarian = "bg", czech = "cs", danish = "da", estonian = "et"
    case finnish = "fi", greek = "el", hebrew = "he", hungarian = "hu", indonesian = "id"
    case latvian = "lv", lithuanian = "lt", macedonian = "mk", norwegian = "no", romanian = "ro"
    case slovak = "sk", slovenian = "sl", thai = "th", turkish = "tr", ukrainian = "uk", vietnamese = "vi"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .dutch: return "Dutch"
        case .polish: return "Polish"
        case .swedish: return "Swedish"
        case .croatian: return "Croatian"
        case .serbian: return "Serbian"
        case .bosnian: return "Bosnian"
        case .albanian: return "Albanian"
        case .bulgarian: return "Bulgarian"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .estonian: return "Estonian"
        case .finnish: return "Finnish"
        case .greek: return "Greek"
        case .hebrew: return "Hebrew"
        case .hungarian: return "Hungarian"
        case .indonesian: return "Indonesian"
        case .latvian: return "Latvian"
        case .lithuanian: return "Lithuanian"
        case .macedonian: return "Macedonian"
        case .norwegian: return "Norwegian"
        case .romanian: return "Romanian"
        case .slovak: return "Slovak"
        case .slovenian: return "Slovenian"
        case .thai: return "Thai"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .vietnamese: return "Vietnamese"
        }
    }

    /// UI picker tuple list (id + label), English first.
    static var pickerOptions: [(id: String, label: String)] {
        allCases.map { ($0.rawValue, $0.label) }
    }
}
#endif
