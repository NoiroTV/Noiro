import Foundation

/// Explicit opt-in for Noiro watch-signal telemetry.
///
/// It is off by default. When enabled, payloads must exclude raw playback URLs,
/// credentials, server addresses, payer data, and media. Rights-reviewed Noiro
/// community services remain independently launch-gated.
enum MoatConsent {
    static let key = "noiro.telemetry.optIn"

    static let disclosure = String(localized:
        "Optional. Share coarse title and playback signals to improve Noiro. Raw playback URLs, credentials, server addresses, and media are never included.")

    static var contributeAndConsume: Bool {
        return UserDefaults.standard.bool(forKey: key)
    }
}
