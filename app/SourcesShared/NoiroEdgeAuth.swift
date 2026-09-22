import Foundation

/// Compatibility shim for call sites inherited from the pre-Noiro client.
///
/// Noiro never embeds a shared service secret. A secret inside a customer-signed
/// application is extractable and cannot establish that a request came from an
/// authentic release. Vortexo services that need authorization instead use the
/// device-bound bearer issued by `/api/noiro/v1/pairing/*`.
///
/// Keep this no-op until every old call site is replaced by a rights-reviewed
/// Noiro service client. Its presence deliberately cannot add headers, signing
/// keys, host allowlists, or legacy credentials to a request.
enum NoiroEdgeAuth {
    static func sign(_ request: inout URLRequest) {
        // Intentionally empty. See the security boundary above.
    }
}
