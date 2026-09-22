import Foundation

/// Short-lived MOAT token issuer + cache for the Noiro community SERVE side.
///
/// The gated community pools (`vortexo.app/api/noiro/v1/edge/sources` Singularity, `vortexo.app/api/noiro/v1/edge/subtitles`, trickplay-serve) do NOT
/// merely edge-sign reads with `NoiroEdgeAuth`; their READ path additionally requires a per-account MOAT token
/// (`verifyMoatToken` on the worker: no token => empty list, a HARD login gate). CONTRIBUTE stays open, only
/// SERVE is moat-gated. The token is minted by the issuer at `vortexo.app/api/noiro/v1/edge/api`, is short-lived, and must be
/// refreshed before it expires. This is the client that fetches, caches (with expiry), refreshes, and stamps
/// it onto outgoing gated reads.
///
/// FAIL-SOFT CONTRACT (every method): no token, a mint error, offline, a signed-out account, or a withdrawn
/// consent all collapse to "no token" -> the caller stamps nothing -> the gated read returns empty. Nothing
/// throws to a caller and nothing ever blocks or crashes. A missing token is a normal, expected state (the
/// whole app works signed out), so it is never surfaced as an error.
///
/// IDENTITY: the mint is authenticated with the Noiro account session bearer (the `vortexo.app/api/noiro/v1/edge/api` session token
/// that `NoiroDocumentSyncManager` persists), NOT the Stremio `authKey` (Keychain-only, goes solely to api.strem.io per
/// the account invariant). Read directly from the same Keychain slot so this stays self-contained.
///
/// GATING: minting is gated on `MoatConsent.contributeAndConsume` (give-to-get: no consent -> no moat token ->
/// no SERVE) AND on the caller-supplied signed-in flag. A signed-out or opted-out device never mints.
///
/// CONCURRENCY: an `actor` so the cache + in-flight mint are race-free; a burst of gated reads (sources + subs
/// + trickplay all firing on one detail open) shares ONE mint instead of stampeding the issuer.
actor MoatToken {
    static let shared = MoatToken()

    // MARK: - Cache state

    /// The cached token + its absolute expiry. nil until a first successful mint (and after a hard clear).
    private var cached: (token: String, expiresAt: Date)?
    /// A single in-flight mint shared by concurrent callers, so N simultaneous gated reads mint once.
    private var inFlight: Task<String?, Never>?
    /// Monotonic tag identifying the current mint. clear() bumps it so a stale mint's store()/clearInFlight
    /// (which run after its await returns) cannot clobber a newer mint's state.
    private var mintGeneration: UInt64 = 0

    /// Refresh the token this far BEFORE its stated expiry, so a read never rides an about-to-die token across
    /// the worker's clock skew. 60 s covers a slow mint + request latency.
    private let refreshSkew: TimeInterval = 60

    // MARK: - Public API

    /// The current valid moat token, minting or refreshing as needed. Returns nil (never throws) when the
    /// device cannot or should not hold one: opted out of the pool, signed out, offline, or the mint failed.
    ///
    /// `isSignedIn` is the caller's account signed-in flag (the SERVE gate is login-only). Passed in rather
    /// than read here so this stays free of a SwiftUI/main-actor dependency and testable.
    func current(isSignedIn: Bool) async -> String? {
        guard MoatConsent.contributeAndConsume, isSignedIn else {
            // Opted out or signed out: drop any stale token so a later opt-in / sign-in re-mints cleanly.
            cached = nil
            return nil
        }
        // Fresh cached token (with skew headroom): hand it straight back.
        if let c = cached, c.expiresAt.timeIntervalSinceNow > refreshSkew {
            return c.token
        }
        // Coalesce concurrent mints onto one task.
        if let task = inFlight { return await task.value }
        // Tag each mint with a token so store()/clearInFlight only act when THIS mint still owns inFlight; a
        // concurrent clear()/re-mint bumps the tag so a stale task cannot clobber the newer one.
        mintGeneration &+= 1
        let generation = mintGeneration
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            let minted = await Self.mint()
            // A concurrent clear() cancels this task and may have already started a fresh mint; if so, do not
            // store a stale result or clear the newer in-flight pointer (which would defeat coalescing).
            if Task.isCancelled { return nil }
            await self.store(minted, generation: generation)
            await self.clearInFlight(generation: generation)
            return minted?.token
        }
        inFlight = task
        return await task.value
    }

    /// Proactively warm the token (e.g. right after login) so the first gated read does not pay the mint
    /// latency. Fire-and-forget; result ignored. No-op when opted out / signed out / already warm.
    func prewarm(isSignedIn: Bool) async {
        _ = await current(isSignedIn: isSignedIn)
    }

    /// Drop the cached token (e.g. on sign-out / consent withdrawal). The next `current` re-mints.
    func clear() {
        cached = nil
        inFlight?.cancel()
        inFlight = nil
        mintGeneration &+= 1   // orphan any in-flight mint so its late store()/clearInFlight is a no-op
    }

    // MARK: - Header stamping helpers

    /// Stamp the moat token onto a gated READ `request` as `X-Noiro-Moat`. No-op when there is no token (the
    /// worker then returns an empty list, which is the correct fail-soft SERVE result). Call AFTER
    /// `NoiroEdgeAuth.sign` so both the edge signature and the moat token ride together.
    func stamp(_ request: inout URLRequest, isSignedIn: Bool) async {
        guard let token = await current(isSignedIn: isSignedIn) else { return }
        request.setValue(token, forHTTPHeaderField: Self.header)
    }

    /// The moat token as a query-param value for `<img>`/`<video>` element loads that cannot carry a custom
    /// header (trickplay sprites, pooled art). Returns nil when there is no token. The worker reads `vmoat`
    /// as the query fallback for `X-Noiro-Moat`, mirroring the `NoiroEdgeAuth` query-sig convention.
    ///
    /// LEAKAGE NOTE: prefer `stamp(_:isSignedIn:)` (the header path) wherever the loader can carry a header; a
    /// token on the URL is short-lived but can otherwise linger in logs and the persistent URLCache. Callers
    /// that must use this query form MUST NOT log the built URL and SHOULD load it on an ephemeral session so
    /// the token is not written to the on-disk cache. This type itself logs nothing.
    func queryValue(isSignedIn: Bool) async -> String? {
        await current(isSignedIn: isSignedIn)
    }

    static let header = "X-Noiro-Moat"
    static let queryParam = "vmoat"

    // MARK: - Mint (issuer round trip)

    private struct Minted { let token: String; let expiresAt: Date }

    /// One mint round trip to the issuer. Fail-soft to nil on any error / non-2xx / decode miss / no session.
    /// POSTs to `<issuer>/moat/token` with the Noiro account session bearer; the worker returns
    /// `{ token, expiresIn?|expiresAt? }`.
    private static func mint() async -> Minted? {
        guard let bearer = sessionBearer(), !bearer.isEmpty else { return nil }   // no Noiro session -> no mint
        // The live issuer route is /v1/moat/token (vortexo.app/api/noiro/v1/edge/api). The un-versioned /moat/token 404s, so a
        // tokenless app never un-gates the moat SERVE (Singularity sources, pooled subs) - this is that fix.
        guard let url = URL(string: issuerBase + "/v1/moat/token") else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue("Bearer " + bearer, forHTTPHeaderField: "authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(MintResponse.self, from: data),
              let token = decoded.token, !token.isEmpty else { return nil }

        let ttl = decoded.expiresIn.map { TimeInterval($0) }
        let expiresAt: Date
        if let at = decoded.expiresAt { expiresAt = Date(timeIntervalSince1970: TimeInterval(at)) }
        else if let ttl { expiresAt = Date().addingTimeInterval(ttl) }
        else { expiresAt = Date().addingTimeInterval(defaultTTLStatic) }
        return Minted(token: token, expiresAt: expiresAt)
    }

    /// The issuer base, baked to vortexo.app/api/noiro/v1/edge/api. The `endpoint("moat")` lookup is a forward hook: RemoteConfig has
    /// no `moat` endpoint wired today (`endpoint(_:)` returns nil for it), so this always resolves to the baked
    /// default until a `moat` key is decoded + returned there. Repoint by wiring that key, not by editing here.
    private static var issuerBase: String {
        RemoteConfig.snapshot.endpoint("moat")?.absoluteString ?? "https://vortexo.app/api/noiro/v1/legacy-disabled"
    }

    private static let defaultTTLStatic: TimeInterval = 15 * 60

    /// The Noiro device bearer, read from the passwordless pairing Keychain
    /// record (NOT the Stremio authKey). A missing/garbled record yields nil,
    /// which fails the mint soft. Kept here so the client is
    /// self-contained and never reaches into another type's private state.
    private static func sessionBearer() -> String? {
        guard let raw = Keychain.string(noiroSessionSlot),
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = obj["accessToken"] as? String, token.hasPrefix("noiro_") else { return nil }
        return token
    }

    /// Same passwordless authorization slot as `NoiroSyncManager`.
    private static let noiroSessionSlot = "noiro.sync.device-authorization.v1"

    // MARK: - Actor-isolated mutators (called from the mint Task)

    private func store(_ minted: Minted?, generation: UInt64) {
        guard generation == mintGeneration else { return }   // a clear()/re-mint superseded this mint: drop it
        guard let minted else { return }   // keep any still-valid cached token on a failed refresh
        cached = (token: minted.token, expiresAt: minted.expiresAt)
    }

    /// Clear the in-flight pointer only if this generation still owns it, so a stale mint completing after a
    /// concurrent clear()/re-mint does not null out the newer in-flight task (which would defeat coalescing).
    private func clearInFlight(generation: UInt64) {
        guard generation == mintGeneration else { return }
        inFlight = nil
    }

    // MARK: - Wire shape

    private struct MintResponse: Decodable {
        let token: String?
        let expiresIn: Int?    // seconds-to-live
        let expiresAt: Int?    // absolute unix seconds (preferred when present)
    }
}
