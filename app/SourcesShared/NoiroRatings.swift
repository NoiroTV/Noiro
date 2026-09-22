import Foundation

/// Noiro's rights-gated ratings adapter (https://vortexo.app/api/noiro/v1/edge/ratings): cross-provider ratings with NO user key
/// required. IMDb is keyless (sourced from Cinemeta); Rotten Tomatoes / Metacritic / TMDB come from a
/// single Noiro-owned MDBList key held server-side, so no user ever needs their own. Fails soft (returns
/// nil) like MDBListClient, and maps into the SAME MDBListRatings model so the detail ratings row renders
/// unchanged. On by default; a power user can disable it or point at their own instance via the keys below.
enum NoiroRatingsClient {
    static let baseKey = "noiro.ratings.base"       // optional override; blank = the Noiro service
    static let enabledKey = "noiro.ratings.enabled" // absent = on by default

    /// Service base URL, http(s) only, trailing slash trimmed; defaults to the Noiro service.
    static var base: String {
        var s = (UserDefaults.standard.string(forKey: baseKey) ?? "").trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return "https://vortexo.app/api/noiro/v1/edge/ratings" }
        return s.isEmpty ? "https://vortexo.app/api/noiro/v1/edge/ratings" : s
    }

    /// On unless the user explicitly turned it off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Ratings for an IMDb id, no key needed. `type` is the stremio type ("movie"/"series"). Returns nil
    /// when disabled, the id is not an imdb id, or anything goes wrong (fail-soft, like MDBListClient).
    static func ratings(imdbID: String, type: String) async -> MDBListRatings? {
        guard isEnabled, imdbID.hasPrefix("tt") else { return nil }
        let mediaType = (type == "series") ? "series" : "movie"
        guard let url = URL(string: "\(base)/v1/ratings/\(mediaType)/\(imdbID)") else { return nil }
        do {
            // Sign for the gated vortexo.app/api/noiro/v1/edge/ratings host (no-op when the user pointed at a custom base).
            var request = URLRequest(url: url)
            NoiroEdgeAuth.sign(&request)
            let (data, resp) = try await URLSession.shared.data(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            // The Noiro adapter returns IMDb on its native 0-10 scale and RT / Metacritic / TMDB as 0-100,
            // matching the MDBListRatings model the detail row already renders.
            let r = MDBListRatings(
                imdb: numeric(root["imdb"]),
                rottenTomatoes: numeric(root["rt"]).map { Int($0.rounded()) },
                metacritic: numeric(root["metacritic"]).map { Int($0.rounded()) },
                tmdb: numeric(root["tmdb"]).map { Int($0.rounded()) }
            )
            return r.hasAny ? r : nil
        } catch { return nil }
    }

    private static func numeric(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
