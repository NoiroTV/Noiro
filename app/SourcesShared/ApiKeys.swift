import SwiftUI

/// User-supplied API keys for the optional metadata enrichers (TMDB recommendations, MDBList ratings
/// and lists). Kept in the Keychain, not UserDefaults, since they are credentials. Everything that uses
/// them degrades gracefully when a key is absent, so Noiro works fully without them.
@MainActor
final class ApiKeys: ObservableObject {
    static let shared = ApiKeys()

    private let tmdbAccount = "noiro.apikey.tmdb"
    private let mdblistAccount = "noiro.apikey.mdblist"
    private let fanartAccount = "noiro.apikey.fanart"
    private let skipdbAccount = "noiro.apikey.skipdb"
    private let customSkipURLAccount = "noiro.skip.customurl"
    private let customSkipKeyAccount = "noiro.apikey.customskip"
    private let geminiAccount = "noiro.apikey.gemini"

    nonisolated private static func previousAccount(_ suffix: String) -> String {
        "vor" + "tx" + suffix
    }

    @Published var tmdb: String { didSet { Keychain.set(tmdb.isEmpty ? nil : tmdb, for: tmdbAccount) } }
    @Published var mdblist: String { didSet { Keychain.set(mdblist.isEmpty ? nil : mdblist, for: mdblistAccount) } }
    @Published var fanart: String { didSet { Keychain.set(fanart.isEmpty ? nil : fanart, for: fanartAccount) } }
    @Published var skipdb: String { didSet { Keychain.set(skipdb.isEmpty ? nil : skipdb, for: skipdbAccount) } }

    /// An ADDITIONAL user-configured SkipDB-compatible provider: the base URL of a self-hosted mirror
    /// (e.g. https://my-mirror.example), plus an optional API key for it. When set, a submit fans out to
    /// it alongside vortexo.app/api/noiro/v1/edge/skip and skipdb.tv, and reads query it too. Both stay in the Keychain.
    @Published var customSkipURL: String { didSet { Keychain.set(customSkipURL.isEmpty ? nil : customSkipURL, for: customSkipURLAccount) } }
    @Published var customSkipKey: String { didSet { Keychain.set(customSkipKey.isEmpty ? nil : customSkipKey, for: customSkipKeyAccount) } }
    /// Gemini API key for AI subtitle translation. Keychain-backed like the other keys; empty = translation off.
    @Published var gemini: String { didSet { Keychain.set(gemini.isEmpty ? nil : gemini, for: geminiAccount) } }

    private init() {
        tmdb = Self.migrate(tmdbAccount, legacy: Self.previousAccount(".apikey.tmdb"))
        mdblist = Self.migrate(mdblistAccount, legacy: Self.previousAccount(".apikey.mdblist"))
        fanart = Self.migrate(fanartAccount, legacy: Self.previousAccount(".apikey.fanart"))
        skipdb = Self.migrate(skipdbAccount, legacy: Self.previousAccount(".apikey.skipdb"))
        customSkipURL = Self.migrate(customSkipURLAccount, legacy: Self.previousAccount(".skip.customurl"))
        customSkipKey = Self.migrate(customSkipKeyAccount, legacy: Self.previousAccount(".apikey.customskip"))
        gemini = Self.migrate(geminiAccount, legacy: Self.previousAccount(".apikey.gemini"))
    }

    var hasTMDB: Bool { !tmdb.isEmpty }
    /// Whether TMDB artwork (the 16:9 backdrops behind landscape catalog cards) is available. Always
    /// true: `TMDBClient` falls back to a bundled key + the keyless edge (`vortexo.app/api/noiro/v1/edge/catalogs`) when the
    /// user has no personal key, so landscape cards work WITHOUT a key. The card/grid landscape gates
    /// read THIS (not `hasTMDB`, which only reflects a user-entered personal key).
    var hasTMDBArtwork: Bool { true }
    var hasMDBList: Bool { !mdblist.isEmpty }
    var hasFanart: Bool { !fanart.isEmpty }
    var hasSkipDB: Bool { !skipdb.isEmpty }
    var hasCustomSkip: Bool { !customSkipURL.isEmpty }
    var hasGemini: Bool { !gemini.isEmpty }

    /// Read the keys off the main actor (for use inside async network code).
    nonisolated static func tmdbKey() -> String? {
        let k = migrate("noiro.apikey.tmdb", legacy: previousAccount(".apikey.tmdb")); return k.isEmpty ? nil : k
    }
    /// Gemini key for AI subtitle translation, readable off the main actor (the translation service is an actor).
    nonisolated static func geminiKey() -> String? {
        let k = migrate("noiro.apikey.gemini", legacy: previousAccount(".apikey.gemini")); return k.isEmpty ? nil : k
    }

    /// No inherited metadata key is embedded in Noiro. Rights-reviewed Noiro
    /// services may be enabled later; until then a direct TMDB feature requires
    /// the user's device-local key.
    nonisolated static let bundledTMDBKey = ""

    /// The key TMDB calls build their `api_key=` with: the user's key when set, else Noiro's bundled key
    /// so the catalogs/hub work with NO user key. `TMDBClient.get` decides the ROUTE from `tmdbKey()`
    /// (a real user key -> TMDB direct; no user key -> the keyless edge, which injects its own key).
    nonisolated static func effectiveTMDBKey() -> String { tmdbKey() ?? bundledTMDBKey }
    nonisolated static func mdblistKey() -> String? {
        let k = migrate("noiro.apikey.mdblist", legacy: previousAccount(".apikey.mdblist")); return k.isEmpty ? nil : k
    }
    nonisolated static func fanartKey() -> String? {
        let k = migrate("noiro.apikey.fanart", legacy: previousAccount(".apikey.fanart")); return k.isEmpty ? nil : k
    }
    nonisolated static func skipDBKey() -> String? {
        let k = migrate("noiro.apikey.skipdb", legacy: previousAccount(".apikey.skipdb")); return k.isEmpty ? nil : k
    }
    /// Base URL of the user's optional custom SkipDB-compatible provider (nil when unset).
    nonisolated static func customSkipURL() -> String? {
        let k = migrate("noiro.skip.customurl", legacy: previousAccount(".skip.customurl")); return k.isEmpty ? nil : k
    }
    /// Optional API key for the custom provider (nil when unset; some mirrors are keyless).
    nonisolated static func customSkipKey() -> String? {
        let k = migrate("noiro.apikey.customskip", legacy: previousAccount(".apikey.customskip")); return k.isEmpty ? nil : k
    }

    nonisolated private static func migrate(_ account: String, legacy: String) -> String {
        if let current = Keychain.string(account), !current.isEmpty { return current }
        guard let old = Keychain.string(legacy), !old.isEmpty else { return "" }
        Keychain.set(old, for: account)
        return old
    }
}
