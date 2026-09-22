import Foundation

/// Portable, device-local export/import of Noiro preferences. Earlier namespaces
/// are translated on import, while credentials remain in the Keychain and are
/// never placed in this JSON file.
///
/// What it captures: this app's OWN UserDefaults domain, which is every preference the app
/// has written (theme, player toggles, audio output, source filters, profiles, server config,
/// seek step, resume positions, ...). It is read via `persistentDomain(forName:)`, so Apple's
/// global domain is excluded, and the keys are literal strings that do not depend on the bundle
/// id, so a StremioX backup repopulates the same keys when restored into Noiro.
///
/// What it deliberately does NOT capture: the Stremio account token lives in the Keychain, not
/// UserDefaults, so it never lands in the backup file. The account (and with it the synced
/// library, add-ons, and history) comes back by signing in again. 0.4 is FREE to rename the
/// Restore runs every key through `migratedKey(_:)`, so older backup files still
/// apply without keeping an inherited configuration namespace active.
enum SettingsBackup {
    static let schema = 1
    static let formatTag = "noiro-backup"

    /// Framework/OS keys that can appear in the app domain but are not our preferences.
    /// Filtered out so the backup stays app-only and a restore never re-seeds OS state.
    private static let skipPrefixes = ["Apple", "NS", "com.apple.", "WebKit", "WebDatabase", "PK", "MetricKit", "INNext"]

    static func isAppPref(_ key: String) -> Bool {
        !skipPrefixes.contains { key.hasPrefix($0) }
    }

    /// PER-DEVICE keys that must NEVER sync or transfer between devices. The cross-device settings sync
    /// The retired compatibility sync code also reuses this serialization. Each
    /// device keeps its own value: the streaming-cache size depends on that device's free storage, and the
    /// streaming server is per-device (one device may point at a custom/local server). A device that pulls a
    /// peer's settings keeps its own cache/server choice; its own choice is never pushed up to overwrite others.
    static let deviceLocalKeys: Set<String> = [
        "noiro.diskCacheBytes",   // Settings -> Streaming cache (sized to the device's own storage)
        "noiro.serverURL",        // custom streaming server URL (per-device)
        "noiro.videoUpscaling",   // Settings -> Video upscaling (per-device: standard on Apple TV, scaled on Mac)
        "noiro.dvRemux",          // Settings -> Dolby Vision for MKV (per-device: depends on THIS device's DV
                                     // display + decode). Was syncing, so a pull kept reverting a freshly-toggled
                                     // device back to a peer's OFF value, which is why enabling it never "took".
    ]

    /// An app preference that is ALSO safe to sync/transfer (i.e. not a per-device-local key).
    static func isSyncable(_ key: String) -> Bool {
        isAppPref(key) && !deviceLocalKeys.contains(key)
    }

    /// One-way compatibility for backup files produced by either inherited
    /// namespace. New backups contain only `noiro.*` keys.
    static let keyPrefixMigrations = ["stremiox.": "noiro.", "noiro.": "noiro."]
    static let keyMigrations: [String: String] = [:]

    static func migratedKey(_ key: String) -> String {
        if let exact = keyMigrations[key] { return exact }
        for (old, new) in keyPrefixMigrations where key.hasPrefix(old) {
            return new + key.dropFirst(old.count)
        }
        return key
    }

    struct Envelope: Codable {
        var format: String
        var schema: Int
        var app: String
        var bundleID: String
        var createdAt: Date
        var keyCount: Int
        var payloadBase64: String   // binary plist of the filtered app defaults domain
    }

    enum RestoreError: LocalizedError {
        case notABackup
        case corruptPayload

        var errorDescription: String? {
            switch self {
            case .notABackup: return "This file is not a Noiro backup."
            case .corruptPayload: return "This backup file is damaged and could not be read."
            }
        }
    }

    // MARK: Pure serialization (unit-testable, no UserDefaults / Bundle dependency)

    /// Wrap a defaults dictionary into the portable JSON envelope. The values pass through a
    /// binary property list, which natively round-trips every UserDefaults value type
    /// (Bool, Int, Double, String, Data, Date, arrays, dictionaries) that raw JSON cannot.
    static func encode(domain: [String: Any], bundleID: String, app: String, now: Date = Date()) throws -> Data {
        let plist = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        let env = Envelope(
            format: formatTag, schema: schema, app: app, bundleID: bundleID,
            createdAt: now, keyCount: domain.count, payloadBase64: plist.base64EncodedString()
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(env)
    }

    /// Validate and unwrap a backup file back into a defaults dictionary (app keys only).
    static func decodeDomain(from data: Data) throws -> [String: Any] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let acceptedFormats = [formatTag, "noiro-backup", "stremiox-backup"]
        guard let env = try? dec.decode(Envelope.self, from: data), acceptedFormats.contains(env.format) else {
            throw RestoreError.notABackup
        }
        guard let plistData = Data(base64Encoded: env.payloadBase64),
              let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let pairs = object as? [String: Any]
        else {
            throw RestoreError.corruptPayload
        }
        var migrated: [String: Any] = [:]
        for (key, value) in pairs {
            let newKey = migratedKey(key)
            if isSyncable(newKey) { migrated[newKey] = value }
        }
        return migrated   // never apply a peer's per-device keys (cache size, server URL)
    }

    // MARK: App I/O

    /// Suggested filename for the exporter (the `.json` extension is appended from the content type).
    static func defaultFilename() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd-HHmm"
        return "Noiro-Backup-\(df.string(from: Date()))"
    }

    /// Serialize the app's own preferences into a portable, human-inspectable JSON file.
    static func makeBackup() throws -> Data {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let full = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        let domain = full.filter { isSyncable($0.key) }   // exclude per-device keys (cache size, server URL)
        let app = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? "Noiro"
        return try encode(domain: domain, bundleID: bundleID, app: app)
    }

    /// Apply a backup file. Merges keys (overwriting matching ones, leaving the rest), so a
    /// partial backup never wipes settings it does not mention. Returns the number of keys
    /// applied. A relaunch is recommended afterwards so every store re-reads cleanly.
    @discardableResult
    static func restore(from data: Data) throws -> Int {
        let pairs = try decodeDomain(from: data)
        let defaults = UserDefaults.standard
        for (key, value) in pairs {
            defaults.set(value, forKey: migratedKey(key))
        }
        return pairs.count
    }
}
