import Foundation

/// Cross-platform "resolve a trailer to a playable URL" type, compiled into every target
/// (SourcesShared is in all of them). A meta's trailer is either a direct (non-YouTube) stream
/// URL or a YouTube id; this collapses both into one `playableURL` the players can hand to libmpv.
///
/// YouTube trailers resolve to a playable URL with NO embedded server. `playableURL` uses the always-remote
/// `StremioServer.trailerResolverBase` (`vortexo.app/api/noiro/v1/edge/trailer/yt/{id}`); at play time the players additionally try
/// the on-device `YouTubeDirectResolver` (InnerTube) plus the local `VXTrailerProxy` (127.0.0.1) first. So a
/// YouTube-only trailer has a `playableURL` on EVERY scheme, Lite included, and the tvOS Trailer button shows
/// there too. `watchURL` is the public youtube.com link for surfaces that open an external player (iOS/macOS).
struct TrailerRequest: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let youTubeID: String?
    /// A non-YouTube `trailerStreams` url, if the meta carried a direct stream.
    let directURL: URL?
    /// Release year (4 digits) + media type ("movie"/"series"): the key the `/clip` resolver matches a
    /// trailer on (Apple iTunes preview, by title+year), since iTunes has no id we can pass. Defaulted so
    /// callers that lack a year/type (e.g. a home board-row hero) still build a title-only /clip request.
    var year: String? = nil
    var mediaType: String = "movie"
    /// IMDb id (`tt...`) when known: the `/clip` worker keys on it (KinoCheck) to fetch the exact
    /// trailer/clip, preferred over title+year matching. nil for tmdb:/kitsu: catalog ids.
    var imdbID: String? = nil

    /// The libmpv-playable URL for the muted, looping AMBIENT in-hero clip: a direct (non-YouTube) trailer
    /// stream when the meta carried one, else the `/yt/{id}` native resolver URL for the meta's YouTube id
    /// (`StremioServer.trailerResolverBase` + `/yt/{id}`, the SAME path the full Trailer button and our
    /// YouTube URL playback use). The R2 `vortexo.app/api/noiro/v1/edge/trailer/clip` ambient snippet has been RETIRED (owner
    /// directive): now that `/yt` plays the real trailer directly, the ambient background loop is that same
    /// full trailer, just played muted + looping. This is a thin ambient alias of `nativeFullTrailerURL()`.
    ///
    /// FAIL-SOFT: no direct stream and no YouTube id -> nil, and every consumer keeps its still backdrop (no
    /// error is surfaced). A 404 / timeout / undeployed resolver likewise surfaces to the player as
    /// `endFileError` -> still backdrop. A direct stream is always preferred over the resolver. Consumed by
    /// tvOS (`TVInHeroTrailerView` via the detail `heroTrailerLayer` + `HomeHeroTrailerModel`) and the iOS
    /// detail hero's last-resort ambient branch; the WKWebView IFrame (`InHeroYouTubeTrailerView`) using
    /// `youTubeID` is the no-server / Lite fallback where the `/yt` route is unavailable.
    var playableURL: URL? {
        nativeFullTrailerURL()
    }

    /// The public YouTube watch link, for surfaces that open trailers externally.
    var watchURL: URL? {
        youTubeID.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
    }

    /// The FULL-trailer NATIVE playback URL (owner FINAL architecture, HARD): a direct (non-YouTube) trailer
    /// stream when the meta carried one, else the embedded/remote server's `/yt/{id}` resolver (server.js:
    /// InnerTube ANDROID client -> a direct media URL that libmpv/AVPlayer plays natively). This is the SAME
    /// path our YouTube/Twitch URL playback already uses - NOT the vortexo.app/api/noiro/v1/edge/trailer/clip route (that is only
    /// the 10s ambient billboard snippet) and NOT any full-trailer R2 route (the owner rejected R2 full-trailer
    /// storage). Server-gated: on the Lite build (no embedded server) a YouTube-only trailer returns nil, so
    /// the caller falls back to the 10s ambient clip / hides the button - no error screen.
    ///
    /// `preferredYouTubeID` lets a caller pass a language-selected id (D11) that overrides the meta's default
    /// `youTubeID`; the `?lang=` hint carries the resolved base language so the resolver's own fallback chain
    /// (user-lang -> en -> original/any) matches the client pick. The shape MATCHES tvOS `resolveFullTrailerURL`
    /// exactly so a warmed resolve is shared across platforms.
    func nativeFullTrailerURL(preferredYouTubeID: String? = nil, languageCode: String? = nil) -> URL? {
        if let directURL { return directURL }
        let yt = (preferredYouTubeID?.isEmpty == false ? preferredYouTubeID : youTubeID)
        // The remote resolver (vortexo.app/api/noiro/v1/edge/trailer) works on EVERY scheme incl Lite, so no embedded-server gate.
        guard let yt, !yt.isEmpty else { return nil }
        var c = URLComponents(string: "\(StremioServer.trailerResolverBase)/yt/\(yt)")
        let lang = (languageCode?.isEmpty == false) ? languageCode : nil
        if let lang { c?.queryItems = [URLQueryItem(name: "lang", value: lang)] }
        return c?.url
    }

    /// Build from a resolved meta: prefer a direct (non-YouTube) trailer stream url, else fall
    /// back to the YouTube id (`trailerStreams` ytId, or a "Trailer" link). Nil when neither exists.
    static func from(meta: CoreMetaItem) -> TrailerRequest? {
        let direct = (meta.trailerStreams ?? [])
            .compactMap { $0.ytId == nil ? $0.url : nil }
            .compactMap { URL(string: $0) }
            .first
        let yt = meta.trailerYouTubeID
        guard direct != nil || yt != nil else { return nil }
        // 4-digit year from releaseInfo ("2024", "2024-2025", "2024-") so /clip can disambiguate the right
        // film/series; nil if not parseable. type is movie/series.
        let yr = (meta.releaseInfo?.prefix(4)).map(String.init)
        let year = (yr?.count == 4 && yr?.allSatisfy(\.isNumber) == true) ? yr : nil
        let imdbID = meta.id.hasPrefix("tt") ? meta.id : nil
        return TrailerRequest(title: meta.name, youTubeID: yt, directURL: direct,
                              year: year, mediaType: meta.type, imdbID: imdbID)
    }
}

/// Resolves the official trailer attached to an IMDb title to a stable, muxed MP4. YouTube increasingly
/// returns high-resolution GVS URLs that are readable only for the first part of a video unless the client
/// supplies a short-lived proof token. Falling straight to YouTube's progressive itag 18 avoids the cutoff,
/// but leaves an Apple TV playing at 360p. IMDb's title video graph exposes the same official trailer as a
/// signed CloudFront MP4 with video + audio together, normally including 1080p, so it is the preferred native
/// source for IMDb-backed titles. Any API/schema/network miss fails soft to the existing YouTube resolver.
enum IMDbTrailerResolver {
    struct Resolved {
        let videoURL: URL
        let height: Int
        let name: String
    }

    private static let endpoint = URL(string: "https://api.graphql.imdb.com/")!
    private static let timeout: TimeInterval = 5
    private static let cacheTTL: TimeInterval = 60 * 60

    static func resolve(imdbID: String, maxHeight: Int = 1080, languageCode: String? = nil) async -> Resolved? {
        guard imdbID.hasPrefix("tt"), imdbID.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        let cacheKey = "\(imdbID)|\(maxHeight)|\(languageCode ?? "")"
        if let cached = await cache.get(cacheKey) { return cached }

        let query = """
        query($id:ID!){title(id:$id){primaryVideos(first:10){edges{node{id name{value} runtime{value} playbackURLs{mimeType url videoDefinition}}}}}}
        """
        let body: [String: Any] = ["query": query, "variables": ["id": imdbID]]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.imdb.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.imdb.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        if let languageCode, !languageCode.isEmpty {
            request.setValue(languageCode, forHTTPHeaderField: "x-imdb-user-language")
            request.setValue("\(languageCode),en;q=0.8", forHTTPHeaderField: "Accept-Language")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let decoded = try? JSONDecoder().decode(GraphResponse.self, from: data) else { return nil }

            let nodes = decoded.data?.title?.primaryVideos?.edges.map(\.node) ?? []
            let trailerNodes = nodes.enumerated().filter { _, node in
                let name = node.name?.value.lowercased() ?? ""
                return name.contains("trailer") || name.contains("teaser")
            }.sorted { lhs, rhs in
                let l = nameRank(lhs.element.name?.value)
                let r = nameRank(rhs.element.name?.value)
                if l != r { return l < r }
                // IMDb can list several videos with the exact same generic name ("Trailer"). The first is
                // sometimes a short, visibly soft/upscaled TV cut while the longer theatrical master is the
                // genuine HD file (observed on The Invite: 1:09 soft vs 2:02 sharp, both labelled 1080p).
                // Prefer the full trailer inside the same name band; keep source order only as the final tie.
                let lRuntime = lhs.element.runtime?.value ?? 0
                let rRuntime = rhs.element.runtime?.value ?? 0
                return lRuntime != rRuntime ? lRuntime > rRuntime : lhs.offset < rhs.offset
            }.map(\.element)

            for node in trailerNodes {
                let candidates = node.playbackURLs.compactMap { playback -> Resolved? in
                    guard playback.mimeType.lowercased() == "video/mp4",
                          let height = height(from: playback.videoDefinition), height <= maxHeight,
                          let url = URL(string: playback.url),
                          let host = url.host?.lowercased(),
                          host == "media-imdb.com" || host.hasSuffix(".media-imdb.com") else { return nil }
                    return Resolved(videoURL: url, height: height, name: node.name?.value ?? "Trailer")
                }.sorted { $0.height > $1.height }
                if let best = candidates.first {
                    await cache.set(cacheKey, best)
                    NSLog("[imdb-trailer] id=%@ video=%@ h=%d", imdbID, node.id, best.height)
                    return best
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func nameRank(_ raw: String?) -> Int {
        let name = raw?.lowercased() ?? ""
        if name.contains("official trailer") { return 0 }
        if name.contains("trailer") { return 1 }
        return 2
    }

    private static func height(from definition: String?) -> Int? {
        guard let definition else { return nil }
        let digits = definition.filter(\.isNumber)
        return Int(digits)
    }

    private struct GraphResponse: Decodable {
        let data: Payload?
        struct Payload: Decodable { let title: Title? }
        struct Title: Decodable { let primaryVideos: Videos? }
        struct Videos: Decodable { let edges: [Edge] }
        struct Edge: Decodable { let node: Video }
        struct Video: Decodable {
            let id: String
            let name: Name?
            let runtime: Runtime?
            let playbackURLs: [Playback]
        }
        struct Name: Decodable { let value: String }
        struct Runtime: Decodable { let value: Int }
        struct Playback: Decodable {
            let mimeType: String
            let url: String
            let videoDefinition: String?
        }
    }

    private actor ResolveCache {
        private var entries: [String: (value: Resolved, stored: Date)] = [:]

        func get(_ key: String) -> Resolved? {
            guard let entry = entries[key] else { return nil }
            guard Date().timeIntervalSince(entry.stored) < IMDbTrailerResolver.cacheTTL else {
                entries[key] = nil
                return nil
            }
            return entry.value
        }

        func set(_ key: String, _ value: Resolved) {
            entries[key] = (value, Date())
        }
    }

    private static let cache = ResolveCache()
}
