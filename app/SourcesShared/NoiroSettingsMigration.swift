import Foundation

/// One-way, device-local namespace migration for settings created by earlier
/// app identities. Nothing is uploaded, and legacy keys are retained so the
/// untouched duplicate checkout can still read its own data.
enum NoiroSettingsMigration {
    private static let marker = "noiro.migration.settings-namespace.v1"
    private static let previousProductPrefix = "vor" + "tx."

    /// Read before `run()` by the first-install classifier. If this marker was
    /// already present, the device used Noiro before onboarding shipped and
    /// must not be sent through a new-user journey during an upgrade.
    static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: marker)
    }

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }

        let snapshot = defaults.dictionaryRepresentation()
        // Prefer the newer pre-Noiro namespace when both generations contain
        // the same suffix, then fall back to the older StremioX namespace.
        for oldPrefix in [previousProductPrefix, "stremiox."] {
            for (oldKey, value) in snapshot where oldKey.hasPrefix(oldPrefix) {
                let suffix = oldKey.dropFirst(oldPrefix.count)
                let newKey = "noiro." + suffix
                if defaults.object(forKey: newKey) == nil {
                    defaults.set(value, forKey: newKey)
                }
            }
        }

        defaults.set(true, forKey: marker)
    }
}
