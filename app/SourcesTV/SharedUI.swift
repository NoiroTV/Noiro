import SwiftUI
import UIKit

/// Shared, system-aligned building blocks: the poster artwork, the focusable poster card used by every
/// rail and grid, and the empty / not-signed-in state. See Theme.swift for the tokens these use.

/// Standard poster width across the app. Posters are 2:3, so height is `width * 1.5`.
/// Vortexo parity (ScaledDimensions.posterWidth = 230): larger cards read better at ten feet and
/// match the reference project's card proportions. The CatalogPreferences preset ladder scales
/// off this baseline (`.balanced.tvWidth == kPosterWidth`), so changing it rescales every preset.
let kPosterWidth: CGFloat = 230

/// Standard LANDSCAPE catalog-card width on tvOS (16:9, so height = width * 9 / 16 ~= 219pt, shorter than
/// the 300pt poster height, so each rail reads as a cinematic stripe while shrinking vertically).
let kLandscapeCardWidth: CGFloat = 390

/// Poster artwork with a warm placeholder and the system card radius. Not focusable on its own;
/// `PosterCard` wraps it in the focusable button.
///
/// Loads via `.task` + a memory/disk cache rather than `AsyncImage`. `AsyncImage` keeps no cache and
/// cancels in-flight requests during the appear transition without retrying, which left the
/// first (above-the-fold) rails blank on device; a `.task`-driven load re-runs on the next appear and
/// hits the cache instantly.
struct PosterArt: View {
    let poster: String?
    var width: CGFloat = kPosterWidth
    /// Poster corner radius, defaulting to the system card radius. `PosterCard` passes the user's
    /// `posterRadius` preset so the Poster Style corner-radius control is honored on tvOS (#105).
    var radius: CGFloat = Theme.Radius.card
    @State private var image: UIImage?
    @State private var failed = false
    init(_ poster: String?, width: CGFloat = kPosterWidth, radius: CGFloat = Theme.Radius.card) {
        self.poster = poster; self.width = width; self.radius = radius
    }

    /// Paint instantly (no task hop, no blank frame) when the decoded image is already in memory, mirroring the
    /// iOS `CachedPosterImage`. The `.task` still runs to load a cold poster; on a warm one it returns at once.
    private var synchronousCache: UIImage? {
        guard let raw = poster, let u = URL(string: raw) else { return nil }
        return PosterImageLoader.cached(u)
    }

    var body: some View {
        Group {
            if let image = image ?? synchronousCache {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if failed {
                Theme.Palette.surface2.overlay(
                    Image(systemName: "film").font(.system(size: 40)).foregroundStyle(Theme.Palette.textTertiary)
                )
            } else {
                Theme.Palette.surface2.overlay(ProgressView().tint(Theme.Palette.textTertiary))
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: poster) { await load() }
    }

    private func load() async {
        // A recycled cell may still carry the previous title's art in `image`/`failed` (both @State outlive the
        // poster change), so clear them first: a changed URL that fails then shows the placeholder instead of the
        // stale image, and a warm poster repaints instantly from the synchronous cache in `body`.
        image = nil
        failed = false
        guard let raw = poster, !raw.isEmpty else { failed = true; return }   // no poster → film placeholder
        // Shared loader: dedicated large URLCache, bounded concurrency, OFF-MAIN ImageIO decode. Same fix as
        // iOS/Mac (posters were re-fetching through a tiny shared cache and decoding on the main thread).
        if let img = await PosterImageLoader.load(raw) {
            image = img
            return
        }
        if Task.isCancelled { return }   // scroll-away: leave `failed` false so the recycled cell reloads
        // One quick retry before latching the film placeholder, mirroring the iOS `CachedPosterImage`, so a
        // transient network blip on a card that stays on screen (not scrolled away) does not leave it
        // permanently blank. Still bounded (a single retry) so a genuinely dead URL settles fast.
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        if let img = await PosterImageLoader.load(raw) {
            image = img
        } else if !Task.isCancelled {
            failed = true   // a real failure shows the film placeholder; a scroll-away cancel retries next appear
        }
    }
}

/// Which long-press (context) menu a `PosterCard` shows. `.continueWatching` offers a dismiss; `.catalog`
/// offers add-to-library plus mark watched / unwatched; `.library` swaps add for remove-from-library;
/// `.none` attaches no menu at all.
enum PosterMenu { case none, continueWatching, catalog, library }

// MARK: - Catalog rail shell (Vortexo-parity row)

/// The shared horizontal catalog-rail shell: a header over a horizontal scroll of cards, with the
/// Vortexo-parity metrics (48pt side inset, 40pt between cards, `scrollClipDisabled` so the focus
/// halo and the scaled-up focused card render outside the band). Every tvOS catalog rail is built on
/// this so the row rhythm is one source of truth (the six previous inlined copies had drifted).
///
/// The header is generic so a rail can sit under a `RailHeader`, a `GroupHeader`, or nothing. The
/// `content` closure receives nothing and returns the cards (callers put their own `LazyHStack`/
/// `ForEach` inside, including per-row pagination `.onAppear` hooks).
///
/// Rails are intentionally NOT given a fixed frame height: on tvOS Home the hero-strip layout
/// (`kHomeRailStripHeight` + `heroBottomStrip`) already constrains the viewport, and pinning each
/// row's height would double-constrain. Vortexo pins scroll height because it has no equivalent
/// outer constraint.
struct PosterRailShell<Header: View, Content: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header()
            ScrollView(.horizontal, showsIndicators: false) {
                content()
                    .padding(.horizontal, Theme.Space.catalogHorizontal)
                    .padding(.vertical, Theme.Space.lg)   // room for the focus halo
            }
            // Let the row reach the REAL display edge, but never extend its focus viewport beyond it.
            // The compact metrics still preview card five at rest; when that card receives focus, tvOS now
            // knows it is clipped and scrolls it completely on-screen.
            .ignoresSafeArea(.container, edges: .trailing)
            .scrollEdgeEffectStyle(nil, for: .horizontal)
            .scrollClipDisabled()   // Vortexo: the focused card escapes the rail band
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Focused hero (the browse pages' living backdrop)

/// What the browse pages show behind the rails for the title under focus.
struct FocusedHero: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let type: String
    let title: String
    let backdrop: String?     // background art, falling back to the poster
    let metaLine: String      // prebuilt "2026 · ★ 7.6 · Movie" style line
    let overview: String?
    var genreLine: String?    // "Drama · Fantasy · Adventure" (optional so older caches decode)
    var logo: String?         // clearlogo URL (add-on meta.logo or metahub); optional so older caches decode
}

/// The standard Stremio background art for an IMDB-identified title: real 16:9 backdrop art at
/// screen resolution, instead of a portrait poster stretched across the TV.
private func metahubBackground(for id: String) -> String? {
    guard id.hasPrefix("tt") else { return nil }
    return "https://images.metahub.space/background/big/\(id)/img"
}

/// The standard Stremio clearlogo (transparent PNG) for an IMDB-identified title, mirroring the iOS hero
/// seed. Only `tt` ids have metahub art; other id schemes fall back to the add-on `meta.logo` via enrichment.
private func metahubLogo(for id: String) -> String? {
    guard id.hasPrefix("tt") else { return nil }
    return "https://images.metahub.space/logo/medium/\(id)/img"
}

extension CoreMeta {
    var focusedHero: FocusedHero {
        var parts: [String] = []
        if let releaseInfo, !releaseInfo.isEmpty { parts.append(releaseInfo) }
        if let imdbRating, !imdbRating.isEmpty { parts.append("★ \(imdbRating)") }
        parts.append(type.capitalized)
        let genreLine = (genres?.isEmpty == false) ? genres!.prefix(3).joined(separator: " · ") : nil
        return FocusedHero(id: id, type: type, title: name,
                           backdrop: background ?? metahubBackground(for: id) ?? poster,
                           metaLine: parts.joined(separator: "  ·  "), overview: description,
                           genreLine: genreLine, logo: logo ?? metahubLogo(for: id))
    }
}

extension CoreCWItem {
    /// Library entries carry no backdrop or synopsis; real backdrop art comes from metahub and the
    /// synopsis/rating arrive via the model's Cinemeta enrichment a beat later.
    var focusedHero: FocusedHero {
        makeFocusedHero(progress: progress)
    }

    /// Continue Watching can retain a completed mirrored series solely so selecting it resolves the next
    /// episode. Its hero must describe that next-episode placeholder, not repeat "100% watched" from the
    /// episode that supplied the retained engine state.
    var continueWatchingFocusedHero: FocusedHero {
        makeFocusedHero(progress: continueWatchingDisplayProgress)
    }

    private func makeFocusedHero(progress: Double?) -> FocusedHero {
        let pct = progress.map { Int(($0 * 100).rounded()) } ?? 0
        let line = pct > 0 ? "\(type.capitalized)  ·  \(pct)% watched" : type.capitalized
        return FocusedHero(id: id, type: type, title: name,
                           backdrop: metahubBackground(for: id) ?? poster,
                           metaLine: line, overview: nil, genreLine: nil, logo: metahubLogo(for: id))
    }
}

/// Per-page model for the focused hero. Focus changes are debounced so flicking along a rail
/// settles before the backdrop crossfades, and the rails themselves never rebuild (no `.id`),
/// so tvOS focus is never dropped. Heroes without a synopsis (library entries) are enriched from
/// Cinemeta in the background, once per title per session.
@MainActor final class FocusedItemModel: ObservableObject {
    @Published private(set) var hero: FocusedHero?
    /// The text block shows only while focus is in the page's TOP row; deeper rows keep just the
    /// backdrop art, so the details can never collide with content that scrolled up.
    @Published private(set) var detailsVisible = true
    private var pending: Task<Void, Never>?
    private static var enrichmentCache: [String: FocusedHero] = [:]   // session-wide, across pages
    /// Recency order (least-recently-used first) for `enrichmentCache`, so the in-memory map and its on-disk
    /// copy stay bounded instead of growing for every title ever focused.
    private static var enrichmentOrder: [String] = []
    private static let enrichmentCap = 400

    func focus(_ hero: FocusedHero, showsDetails: Bool = true) {
        if hero == self.hero {
            if detailsVisible != showsDetails { detailsVisible = showsDetails }
            return
        }
        pending?.cancel()
        let resolved = Self.resolve(hero)
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.hero = resolved
            self?.detailsVisible = showsDetails
            self?.enrichIfNeeded(resolved)
        }
    }

    /// First render: show something immediately instead of an empty canvas.
    func seedIfEmpty(_ hero: FocusedHero?) {
        guard self.hero == nil, let hero else { return }
        self.hero = Self.resolve(hero)
        detailsVisible = true
        enrichIfNeeded(self.hero ?? hero)
    }

    /// Detail owns one fixed title, but its live watch progress can change while the page remains mounted
    /// behind playback. Refresh that hero immediately without the browse-focus debounce so its metadata
    /// stays identical to the progress-aware Home hero.
    func setFixed(_ hero: FocusedHero) {
        pending?.cancel()
        let resolved = Self.resolve(hero)
        self.hero = resolved
        detailsVisible = true
        enrichIfNeeded(resolved)
    }

    /// A synchronous read of the Cinemeta-enriched hero for an id, if one is already cached (memory +
    /// disk) from a prior focus/detail-page visit. Used by the on-card metadata overlay so a sparse
    /// `MetaPreview` card (Top Picks / Streaming) can show rating/genre/year without a new fetch once
    /// the title has been seen before. Returns nil when nothing is cached yet — the overlay then stays
    /// empty until the card is focused (focus drives `enrichIfNeeded`, populating this cache).
    func enrichedHero(for id: String) -> FocusedHero? {
        Self.loadCacheIfNeeded()
        return Self.enrichmentCache[id]
    }

    /// The cached (detail-page-grade) hero when we have one, keeping the live progress tail
    /// ("62% watched") from the incoming library hero.
    private static func resolve(_ hero: FocusedHero) -> FocusedHero {
        loadCacheIfNeeded()
        guard let cached = enrichmentCache[hero.id] else { return hero }
        touchEnrichment(hero.id)
        let watchedTail = hero.metaLine.components(separatedBy: "  ·  ").first { $0.hasSuffix("% watched") }
        let line = watchedTail.map { "\(cached.metaLine)  ·  \($0)" } ?? cached.metaLine
        return FocusedHero(id: hero.id, type: hero.type, title: hero.title,
                           backdrop: cached.backdrop ?? hero.backdrop,
                           metaLine: line, overview: cached.overview ?? hero.overview,
                           genreLine: cached.genreLine ?? hero.genreLine,
                           logo: cached.logo ?? hero.logo)
    }

    /// Capture what the detail page knows (the engine resolves EVERY id scheme, tmdb: included), so
    /// any title you have opened shows its real backdrop, rating, and synopsis in the hero forever.
    static func noteMeta(id: String, type: String, title: String, backdrop: String?,
                         releaseInfo: String?, imdbRating: String?, runtime: String?,
                         overview: String?, genres: [String]?) {
        loadCacheIfNeeded()
        var parts: [String] = []
        if let releaseInfo, !releaseInfo.isEmpty { parts.append(releaseInfo) }
        if let imdbRating, !imdbRating.isEmpty { parts.append("★ \(imdbRating)") }
        if let runtime, !runtime.isEmpty { parts.append(runtime) }
        parts.append(type.capitalized)
        let genreLine = (genres?.isEmpty == false) ? genres!.prefix(3).joined(separator: " · ") : nil
        let hero = FocusedHero(id: id, type: type, title: title, backdrop: backdrop,
                               metaLine: parts.joined(separator: "  ·  "), overview: overview,
                               genreLine: genreLine, logo: metahubLogo(for: id))
        guard enrichmentCache[id] != hero else { return }
        storeEnrichment(id, hero)
        saveCache()
    }

    // MARK: persistence (survives relaunch, so heroes stay rich without re-opening titles)

    private static var cacheLoaded = false
    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hero-cache.json")
    }

    private static func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: FocusedHero].self, from: data) {
            enrichmentCache = decoded
            enrichmentOrder = Array(decoded.keys)
            enforceEnrichmentCap()   // trim a pre-cap on-disk cache down to the bound on first load
        }
    }

    /// Insert or refresh a hero and mark it most-recently-used, evicting the least-recently-used entries once
    /// the cap is exceeded so neither the in-memory map nor the persisted copy grows without bound.
    private static func storeEnrichment(_ id: String, _ hero: FocusedHero) {
        enrichmentCache[id] = hero
        touchEnrichment(id)
        enforceEnrichmentCap()
    }

    /// Move an id to most-recently-used on a cache hit so an actively focused title survives eviction.
    private static func touchEnrichment(_ id: String) {
        if let i = enrichmentOrder.firstIndex(of: id) { enrichmentOrder.remove(at: i) }
        enrichmentOrder.append(id)
    }

    /// Drop the least-recently-used entries until the map is back within the cap.
    private static func enforceEnrichmentCap() {
        while enrichmentOrder.count > enrichmentCap {
            let evict = enrichmentOrder.removeFirst()
            enrichmentCache.removeValue(forKey: evict)
        }
    }

    private static func saveCache() {
        // Snapshot on the caller (main) and encode + write on a background task so the per-open disk rewrite
        // never blocks the main thread. The dictionary is a value type, so the snapshot is stable off-main.
        let snapshot = enrichmentCache
        let url = cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Base URLs of installed add-ons that serve metas. The enrichment walks these the way the
    /// engine would, so every id scheme works (tt via Cinemeta, tmdb:/tvdb: via their add-ons).
    private static var metaSourceBases: [String] = []

    /// Call whenever the installed add-ons change. Accepts raw transport URLs (.../manifest.json).
    static func configureMetaSources(transportUrls: [String]) {
        metaSourceBases = transportUrls.map { url in
            url.hasSuffix("manifest.json") ? String(url.dropLast("manifest.json".count)) : url
        }
    }

    /// Pre-fetch details for rail items (Continue Watching especially) so the hero is already rich
    /// the moment a card takes focus.
    func warm(_ heroes: [FocusedHero]) {
        Self.loadCacheIfNeeded()
        for hero in heroes.prefix(15) { enrichIfNeeded(hero, apply: false) }
    }

    /// Fill in synopsis / rating / year / genres (and better art) for heroes that came from sparse
    /// library data. Tries Cinemeta for IMDB ids, then every meta-serving add-on the user has
    /// installed. Cached to disk; applied live only if the title is still focused.
    private func enrichIfNeeded(_ hero: FocusedHero, apply: Bool = true) {
        Self.loadCacheIfNeeded()
        guard hero.overview == nil, Self.enrichmentCache[hero.id] == nil else { return }
        let candidates = Self.metaURLs(for: hero)
        guard !candidates.isEmpty else { return }
        Task { [weak self] in
            for url in candidates {
                var request = URLRequest(url: url)
                request.timeoutInterval = 6
                request.cachePolicy = .returnCacheDataElseLoad
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let decoded = try? JSONDecoder().decode(AddonMetaResponse.self, from: data),
                      let meta = decoded.meta,
                      meta.description != nil || meta.background != nil else { continue }
                var parts: [String] = []
                if let year = meta.releaseInfo, !year.isEmpty { parts.append(year) }
                if let rating = meta.imdbRating, !rating.isEmpty { parts.append("★ \(rating)") }
                if let runtime = meta.runtime, !runtime.isEmpty { parts.append(runtime) }
                // Keep the type, but drop any progress tail: it is stale by the next read, and
                // resolve() re-attaches the live one.
                let stableTail = hero.metaLine.components(separatedBy: "  ·  ")
                    .filter { !$0.hasSuffix("% watched") }.joined(separator: "  ·  ")
                if !stableTail.isEmpty { parts.append(stableTail) }
                let genreLine = (meta.genres?.isEmpty == false)
                    ? meta.genres!.prefix(3).joined(separator: " · ") : nil
                let enriched = FocusedHero(id: hero.id, type: hero.type, title: hero.title,
                                           backdrop: meta.background ?? hero.backdrop,
                                           metaLine: parts.joined(separator: "  ·  "),
                                           overview: meta.description, genreLine: genreLine,
                                           logo: meta.logo ?? hero.logo)
                await MainActor.run {
                    Self.storeEnrichment(hero.id, enriched)
                    Self.saveCache()
                    guard apply, let self, self.hero?.id == hero.id else { return }
                    self.hero = Self.resolve(hero)   // re-resolve so the live progress tail merges in
                }
                return
            }
        }
    }

    private static func metaURLs(for hero: FocusedHero) -> [URL] {
        var bases = metaSourceBases
        if hero.id.hasPrefix("tt") { bases.insert("https://v3-cinemeta.strem.io/", at: 0) }
        return bases.compactMap { URL(string: "\($0)meta/\(hero.type)/\(hero.id).json") }
    }
}

/// The Stremio add-on protocol's meta response, the fields the hero uses. Same shape for
/// Cinemeta and every catalog add-on.
private struct AddonMetaResponse: Decodable {
    struct Meta: Decodable {
        let description: String?
        let imdbRating: String?
        let releaseInfo: String?
        let background: String?
        let runtime: String?
        let genres: [String]?
        let logo: String?
    }
    let meta: Meta?
}

/// Invisible focus probe placed inside a focusable button's label: `isFocused` from the
/// environment reflects the button's focus (the documented tvOS pattern), and the callback
/// fires on gain only.
struct FocusReporter: View {
    @Environment(\.isFocused) private var isFocused
    let onFocus: () -> Void
    var body: some View {
        Color.clear.onChange(of: isFocused) { if isFocused { onFocus() } }
    }
}

extension View {
    /// Cages a browse page's scrolling content in a bottom strip. The focus engine centers focused
    /// rows inside THIS viewport, so they are geometrically incapable of riding up over the hero;
    /// rows leaving the strip fade out at its top edge instead of clipping hard.
    func heroBottomStrip(height: CGFloat = 470) -> some View {
        mask(VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 50)
            Color.black
        })
        .frame(height: height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// The native artwork resolution the hero panel renders at: a 720p (1280×720) panel anchored
/// TOP-TRAILING, mirroring Vortexo's `HeroBackdropLayer`. Capped to the actual screen at runtime so a
/// smaller TV never overflows. The panel's leading + bottom edges fade into the canvas via
/// `HeroBackdropCornerFade`; the details block (bottom-leading) reads over the canvas to the left.
/// The shared hero artwork panel uses Vortexo's native 1280×720 editorial size across every tvOS surface.
/// It remains capped to the actual screen at runtime so a smaller TV never overflows.
private let kHeroPanelWidth: CGFloat = 1280
private let kHeroPanelHeight: CGFloat = 720

/// The Vortexo-style hero artwork panel: the focused title's backdrop art rendered as a panel anchored
/// to the TOP-TRAILING corner of the screen, NOT a full-bleed wash. The panel is masked by
/// `HeroBackdropCornerFade` so its leading and bottom edges dissolve into the canvas (no hard
/// rectangle), and a gentle scrim stack sits on top so the left-aligned details block and the bottom
/// rows stay legible against both the still art and the ambient trailer clip.
///
/// The trailer clip is injected as a trailing-closure layer INSIDE the panel (over the still art,
/// under the scrims), so the muted ambient trailer plays in the same framed slot — mirroring Vortexo's
/// `HeroBackdropLayer`, where the moving backdrop occupies the panel and the page chrome floats over it.
/// The still art is the permanent fallback (trailer view stays opacity-0 until it really decodes), so a
/// missing/slow clip never leaves the band black.
///
/// Mirrors `HeroBackdropLayer.swift` + `HeroBackdropCornerFadeMask` in the Vortexo reference project.
struct HeroArtworkPanel<TrailerLayer: View>: View {
    let url: String?
    @ViewBuilder var trailer: () -> TrailerLayer
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        GeometryReader { proxy in
            // Vortexo parity (HeroBackdropLayer.swift): the artwork is a 1280×720 panel capped to the
            // screen, anchored top-trailing. The leading + bottom edges fade into the canvas via the
            // corner-fade mask; the full-screen Vortexo scrims (outside the panel) blend the panel into
            // the hero so the 720p slot reads as one cohesive backdrop, not a floating rectangle.
            // One shared 1280x720 editorial panel across Home, Discover, Library, Live, browse grids, and
            // Detail. Scale only if the available WIDTH is genuinely narrower. Detail intentionally offers
            // a shorter safe-area height than Home; using that height to scale the panel made Detail smaller
            // and changed the crop. The panel may overflow that height because this presentation layer
            // ignores safe areas and is anchored at the screen's top-trailing edge.
            let requestedWidth = kHeroPanelWidth
            let requestedHeight = kHeroPanelHeight
            let widthScale = max(0, proxy.size.width / requestedWidth)
            let panelScale = min(1, widthScale)
            let w = requestedWidth * panelScale
            let h = requestedHeight * panelScale
            ZStack(alignment: .topTrailing) {
                Color.clear
                ZStack(alignment: .topTrailing) {
                    // The still backdrop art, filling the panel. Most focused titles resolve a 16:9
                    // TMDB/metahub backdrop, so .fill is correct; a series that falls back to a portrait
                    // poster crops to the panel like Vortexo's hero backdrop does.
                    AsyncImage(url: URL(string: url ?? "")) { phase in
                        switch phase {
                        case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                        default: Theme.Palette.surface1
                        }
                    }
                    // The ambient trailer clip fills the SAME panel (it self-sizes to .infinity and carries
                    // its own scrim); over the still art, under the Vortexo scrims below.
                    trailer()
                    // Vortexo scrim stack (HeroBackdropLayer.swift), tuned so the artwork stays VISIBLE
                    // across the panel: Vortexo runs the leading scrim up to 0.96 black because the logo
                    // sits over it on a pure-black screen; here the details block sits OUTSIDE the panel on
                    // the warm canvas, so the leading scrim is just a gentle legibility lift, not a wall.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.38), location: 0),
                        .init(color: .black.opacity(0.22), location: 0.2),
                        .init(color: .black.opacity(0.08), location: 0.4),
                        .init(color: .clear, location: 0.6)
                    ], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.76),
                        .init(color: .black.opacity(0.14), location: 0.92),
                        .init(color: .black.opacity(0.42), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: w, height: h)
                .mask(HeroBackdropCornerFade())
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        // Extend into the safe area so the panel's topTrailing anchor + GeometryReader measure the FULL
        // screen and the artwork reaches the true top-right corner — otherwise the tvOS safe-area insets
        // (~60pt top/right) leave a gap of empty canvas around the panel on every edge.
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The corner-fade mask Vortexo's `HeroBackdropLayer` applies (`HeroBackdropCornerFadeMask`): the
/// panel's leading edge fades clear→opaque and the bottom edge fades opaque→clear, so the artwork
/// dissolves into the surrounding canvas on those two edges instead of a hard rectangle. The leading
/// fade starts at 0 (fully transparent) and ramps across ~22% so there is no visible seam where the
/// masked artwork meets the canvas; the bottom fade is stronger where the panel meets the rail strip.
struct HeroBackdropCornerFade: View {
    var body: some View {
        Rectangle()
            .fill(Color.white)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.35), location: 0.06),
                .init(color: .white, location: 0.22),
                .init(color: .white, location: 1)
            ], startPoint: .leading, endPoint: .trailing))
            .mask(
                LinearGradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.86),
                    .init(color: .white.opacity(0.82), location: 0.94),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
    }
}

/// The browse pages' background layer: the focused title's artwork as a Vortexo-style top-trailing
/// panel with a detail block (title, meta line, synopsis) on the bottom-left band. Content scrolls over it.
struct BrowseHeroBackdrop<TrailerLayer: View>: View {
    @ObservedObject var model: FocusedItemModel
    var detailsTop: CGFloat = 90   // Home: just under the tab bar; grid pages: below their chips
    /// When set, the block's BOTTOM is pinned this far above the container's bottom edge instead of
    /// using `detailsTop`. The rails strip anchors to the same edge, so the two can never collide
    /// even as the tab bar shows or hides and shifts the top safe area.
    var detailsBottom: CGFloat? = nil
    /// Moves only the artwork/trailer panel. Detail lowers the complete shared panel while its logo,
    /// metadata, crop, dimensions, and fade remain identical to Home.
    var artworkVerticalOffset: CGFloat = 0
    /// The ambient muted trailer clip, layered BETWEEN the still backdrop and the details block so the
    /// logo / title / meta / synopsis stay legible OVER the clip (identical to how they read over the
    /// still art). Home passes its focus-settled `TVInHeroTrailerView` here; grid pages pass nothing
    /// (the default `EmptyView`), so their still-art heroes are unchanged. Previously the clip was an
    /// `.overlay` on this view, which painted it ABOVE the details and blanked the hero of all its text
    /// while the clip played.
    var trailer: () -> TrailerLayer
    @EnvironmentObject private var theme: ThemeManager
    /// The focused title's clean TMDB clearlogo (textless PNG), resolved by id like the landscape cards.
    /// nil until it resolves (or when TMDB has none / no key) - the title then falls back to styled text.
    @State private var heroLogo: UIImage?

    init(
        model: FocusedItemModel,
        detailsTop: CGFloat = 90,
        detailsBottom: CGFloat? = nil,
        artworkVerticalOffset: CGFloat = 0,
        @ViewBuilder trailer: @escaping () -> TrailerLayer = { EmptyView() }
    ) {
        self.model = model
        self.detailsTop = detailsTop
        self.detailsBottom = detailsBottom
        self.artworkVerticalOffset = artworkVerticalOffset
        self.trailer = trailer
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The canvas owns the screen; the artwork is a Vortexo-style PANEL anchored top-trailing,
            // not a full-bleed wash. The details block (bottom-leading) reads over the canvas + the
            // faded leading/bottom edge of the panel.
            Theme.Palette.canvas.ignoresSafeArea()
            if let hero = model.hero {
                HeroArtworkPanel(url: hero.backdrop) {
                    // The muted trailer clip shares the panel's frame + mask, so an ambient clip becomes
                    // the moving background in the SAME top-trailing slot (still under the details block).
                    trailer()
                }
                .offset(y: artworkVerticalOffset)
                .id(hero.id)
                .transition(.opacity)
                if model.detailsVisible {
                    positioned(HeroMediaInfoBlock(hero: hero, logo: heroLogo)
                        .frame(maxWidth: 860, alignment: .leading)
                        .padding(.leading, Theme.Space.catalogChromeHorizontal))
                        .id("details-\(hero.id)")
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: model.hero?.id)
        .animation(.easeOut(duration: 0.25), value: model.detailsVisible)
        // Resolve the focused title's clearlogo by id (TMDB, same source as the landscape cards) so the
        // hero shows the logo in place of the serif title text, matching the iOS/Mac hero. Re-runs per hero.
        .task(id: model.hero?.id) { await loadHeroLogo() }
        // No ignoresSafeArea here: the canvas layer handles its own full-bleed, and keeping this
        // container inside the safe area lets the tab bar reclaim focus when you press up at the top.
    }

    @ViewBuilder private func positioned<Content: View>(_ content: Content) -> some View {
        if let detailsBottom {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, detailsBottom)
        } else {
            content.padding(.top, detailsTop)
        }
    }

    /// Resolve + load the focused hero's clearlogo. Resets immediately on every hero change so the title
    /// text shows at once, then swaps to the logo when it resolves (nil = TMDB has none / no key = text stays).
    private func loadHeroLogo() async {
        heroLogo = nil
        guard let hero = model.hero else { return }
        // fanart.tv clearlogo first (when enabled), else the ERDB-aware add-on/metahub logo. Both fail-soft.
        let resolved = await Fanart.logo(id: hero.id, type: hero.type)
            ?? PosterArtwork.logo(id: hero.id, fallback: hero.logo ?? metahubLogo(for: hero.id))
        guard let lg = resolved, let img = await fetchHeroImage(lg) else { return }
        heroLogo = img
    }

    private func fetchHeroImage(_ raw: String) async -> UIImage? {
        // Shared loader: dedicated large URLCache, bounded concurrency, off-main ImageIO decode, retry. The
        // living-hero backdrop is a wide 16:9 image, so allow a larger downsample ceiling to keep it crisp.
        await PosterImageLoader.load(raw, maxPixel: 1280)
    }
}

/// The exact title/logo, metadata, secondary information, and synopsis composition used by Home's hero.
/// Other hero surfaces reuse this block so typography, reserved line slots, and vertical rhythm cannot drift.
struct HeroMediaInfoBlock: View {
    let hero: FocusedHero
    let logo: UIImage?

    var body: some View {
        let genre = hero.genreLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let overview = hero.overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let meta = hero.metaLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let textScale = CGFloat(ThemeManager.shared.textScale)
        let titleSlotHeight: CGFloat = 200
        // Metadata can arrive a moment after focus for add-on catalog items. Give both single-line
        // fields fixed viewports so neither an empty/loading value nor a different font glyph box can
        // alter the bottom-aligned hero's measured height during rapid left/right navigation.
        let labelSlotHeight = (34 * textScale).rounded(.up)
        // Five 24pt tvOS body lines plus the configured inter-line spacing. This must be an
        // explicit viewport rather than `reservesSpace`: the hero is bottom-aligned, so any
        // natural Text height change would otherwise move the rail when focus changes titles.
        let overviewSlotHeight = (166 * textScale).rounded(.up)
        let blockHeight = titleSlotHeight
            + 14 + labelSlotHeight
            + 6 + labelSlotHeight
            + 18 + overviewSlotHeight

        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let logo {
                    // The clearlogo IS the title in image form; expose the name to VoiceOver, not the art.
                    Image(uiImage: logo).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 620, maxHeight: 200, alignment: .leading)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                        .accessibilityLabel(hero.title)
                } else {
                    Text(hero.title)
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2).minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                }
            }
            // Logo resolution is asynchronous on Home. Keep one invariant title slot so swapping the
            // temporary text fallback for the larger logo cannot relayout any surface that uses this block.
            .frame(width: 620, height: titleSlotHeight, alignment: .bottomLeading)
            Text(meta.isEmpty ? " " : meta)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 740, height: labelSlotHeight, alignment: .topLeading)
                .clipped()
                .opacity(meta.isEmpty ? 0 : 1)
                .padding(.top, 14)
            Text(genre.isEmpty ? " " : genre)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 740, height: labelSlotHeight, alignment: .topLeading)
                .clipped()
                .opacity(genre.isEmpty ? 0 : 1)
                .padding(.top, 6)
            Text(overview.isEmpty ? " " : overview)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(5)
                .lineSpacing(5)
                .frame(width: 740, height: overviewSlotHeight, alignment: .topLeading)
                .clipped()
                .opacity(overview.isEmpty ? 0 : 1)
                .padding(.top, 18)
        }
        // The complete unit is invariant, not only the synopsis. Home pins this block above its rail;
        // fixing the outer measurement prevents delayed metadata or focus changes from nudging that rail.
        .frame(width: 740, height: blockHeight, alignment: .topLeading)
        .clipped()
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}

/// Cinematic LANDSCAPE artwork for a catalog card: a 16:9 cell filled with the title's CLEAN TMDB backdrop
/// (textless, no rating overlay), resolved by id via `LandscapeBackdropCache`. With no TMDB backdrop (no key
/// set, or none on TMDB) it does NOT crop a 2:3 poster into an ugly slab: it fills with a heavily blurred +
/// darkened copy of the poster and lays the poster fit/centered on top, so the 16:9 frame always looks
/// intentional. The add-on `meta.background` is deliberately NOT used (it is frequently a 2:3 poster URL, the
/// source of the cropped art that got the first landscape attempt reverted). Same cached loader as `PosterArt`.
struct LandscapeArt: View {
    let id: String?
    let type: String
    let title: String
    let poster: String?
    var width: CGFloat = kLandscapeCardWidth
    /// Poster corner radius, defaulting to the system card radius. `PosterCard` passes the user's
    /// `posterRadius` preset so the Poster Style corner-radius control is honored on tvOS (#105).
    var radius: CGFloat = Theme.Radius.card
    @State private var image: UIImage?
    @State private var logo: UIImage?
    @State private var usedBackdrop = false
    @State private var failed = false

    private var height: CGFloat { (width * 9 / 16).rounded() }

    var body: some View {
        Group {
            if let image {
                if usedBackdrop {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .overlay { titleLayer }
                } else {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 26).opacity(0.55)
                        .overlay(Color.black.opacity(0.35))
                        .overlay(Image(uiImage: image).resizable().aspectRatio(contentMode: .fit))
                }
            } else if failed {
                Theme.Palette.surface2.overlay(
                    Image(systemName: "film").font(.system(size: 40)).foregroundStyle(Theme.Palette.textTertiary)
                )
            } else {
                Theme.Palette.surface2.overlay(ProgressView().tint(Theme.Palette.textTertiary))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: id ?? poster ?? "") { await load() }
    }

    /// The title ON the cinematic backdrop: the title's clean TMDB clearlogo when one resolves, else the
    /// title as styled text, both over a bottom scrim so they read on any backdrop.
    @ViewBuilder private var titleLayer: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            if let logo {
                Image(uiImage: logo).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: width * 0.6, maxHeight: height * 0.42, alignment: .bottomLeading)
                    .padding(Theme.Space.md)
            } else {
                Text(title)
                    .font(.system(size: 22, weight: .bold)).lineLimit(2)
                    .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                    .padding(Theme.Space.md)
            }
        }
    }

    private func load() async {
        image = nil; logo = nil; usedBackdrop = false; failed = false
        // Clean TMDB textless 16:9 backdrop (cached by id). Only a real backdrop fills the cell.
        if let id, let bd = await LandscapeBackdropCache.backdrop(id: id, type: type), let img = await fetch(bd) {
            image = img; usedBackdrop = true
            // Title overlay: prefer the clearlogo (PNG); titleLayer falls back to text when nil.
            if let lg = await LandscapeBackdropCache.logo(id: id, type: type) { logo = await fetch(lg) }
            return
        }
        // No TMDB backdrop: composite the poster (blurred fill behind a fit copy), never an ugly 2:3 crop.
        if let img = await fetch(poster) { image = img; usedBackdrop = false; return }
        failed = true
    }

    private func fetch(_ raw: String?) async -> UIImage? {
        guard let raw, !raw.isEmpty else { return nil }
        // Shared loader: dedicated large URLCache, bounded concurrency, off-main ImageIO decode, retry. 16:9
        // backdrops are wider than portrait posters, so allow a larger downsample ceiling to keep the art crisp.
        // Returns nil (without latching a failure) on a scroll-away cancel so the card retries on the next appear.
        return await PosterImageLoader.load(raw, maxPixel: 1280)
    }
}

/// The focusable poster + title used in every rail and grid. Navigates to the detail page; crafted
/// focus (scale + ember glow + lift) comes from `CardFocusStyle`. Optional progress stripe for
/// in-progress titles.
struct PosterCard: View {
    let title: String
    let poster: String?
    let type: String
    let id: String
    var progress: Double? = nil
    /// The saved resume position in seconds, shown as a small "1:03" timecode badge on the poster
    /// (alongside the progress stripe) so Continue Watching cards say where playback resumes. Nil on
    /// every non-CW card, so their tiles are unchanged.
    var resumeSeconds: Double? = nil
    /// Watched state (DESIGN.md "PosterCard — Watched state: 55% opacity plus a check badge").
    /// Mirrors the DetailView episode-thumbnail treatment. Only data-bearing callers pass it
    /// (the Library grid); the default keeps every other card pixel-identical.
    var isWatched: Bool = false
    /// Explicit PORTRAIT card width, for callers that lay cards into FIXED grid cells (TVCategoryBrowse's
    /// 4-across grid) and need the card to EXACTLY fill its cell. nil = the self-sizing rails/surfaces, which
    /// honor the user's Poster Style width preset (#105). A fixed-cell caller MUST pass its cell width or the
    /// preset (134-286pt) overflows the fixed cell and cards overlap their neighbours (#28/#104).
    var width: CGFloat? = nil
    /// Explicit LANDSCAPE card width, for callers that lay cards into FIXED grid cells (TVCategoryBrowse's
    /// 4-across grid). Landscape mode ignores `width` (all rails share one cinematic width), so without
    /// this a fixed-cell grid rendered full-size landscape cards inside narrower cells and neighbouring
    /// tiles overlapped (#28). Nil = the rail-standard kLandscapeCardWidth.
    var landscapeWidth: CGFloat? = nil
    var menu: PosterMenu = .none
    /// Optional on-card metadata (Vortexo parity). When `CatalogPreferences.onCardMeta` is on and ANY of
    /// these is non-nil, the card shows `CardMetaOverlay` (title + footer over a scrim) instead of the
    /// legacy title-below-card. Catalog rows pass these from `CoreMeta` directly (free); sparse
    /// `MetaPreview` rails (Top Picks / Streaming) pass what the focused-hero cache has, so the overlay
    /// populates after the first focus. All default nil so non-data callers render pixel-identical to before.
    var rating: String? = nil
    var year: String? = nil
    var genres: [String]? = nil
    /// Optional focus scale for fixed rails that must remain pixel-stable while focus moves horizontally.
    /// The normal card treatment stays at 1.08; passing 1 keeps the glow/depth without changing geometry.
    var focusScale: CGFloat = 1.08
    var onFocus: (() -> Void)? = nil   // browse pages report focus to drive the hero backdrop
    var directPlay: (() -> Void)? = nil   // Continue Watching: resume the same link straight into the player
    var onDetails: (() -> Void)? = nil    // Continue Watching: open the full detail page from the long-press menu
    /// Person filmography reuses this exact Home card while resolving a raw TMDB credit before it can open
    /// the normal DetailView. Every existing caller leaves this nil and keeps the built-in destination.
    var destination: (() -> AnyView)? = nil
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var apiKeys = ApiKeys.shared
    @ObservedObject private var l10n = LocalizedMetadataStore.shared   // localized title/poster override

    /// The title to show: the pooled localized title in the user's language when available, else the caller's.
    private var displayTitle: String { l10n.title(for: id) ?? title }
    /// Whether the on-card metadata overlay should render. Mirrors Vortexo's `MediaPosterCard`, which
    /// ALWAYS draws the title over a bottom scrim (`landscapeLogoOverlay`) when metadata overlays are on,
    /// independent of whether rating/genre badges are available — the title shows on its own, and the
    /// "Genre · ★ rating" footer is added only when present. So this is just the user's `onCardMeta` toggle.
    private var showsOnCardMeta: Bool {
        catalogPrefs.onCardMeta
    }
    /// The poster to show: the pooled localized (language-matched) poster when available, else the caller's.
    private var displayPoster: String? { l10n.poster(for: id) ?? poster }

    /// Cinematic 16:9 landscape pill vs legacy 2:3 portrait poster, per the Appearance setting. Artwork
    /// is available keylessly through Noiro's catalog edge; a personal TMDB key is optional.
    private var landscape: Bool { catalogPrefs.landscapeCards && apiKeys.hasTMDBArtwork }
    /// Landscape cards use one cinematic width (or the caller's explicit grid-cell width); portrait cards
    /// honor an EXPLICIT caller width (a fixed grid cell) when given, else the user's Poster Style width
    /// preset (#105). Self-sizing rails/surfaces pass nothing (`width == nil`), so the preset drives their
    /// portrait size everywhere; only a fixed-cell grid passes its cell width so the card fills the cell.
    private var cardWidth: CGFloat {
        landscape ? (landscapeWidth ?? kLandscapeCardWidth) : (width ?? catalogPrefs.posterWidth.tvWidth)
    }

    var body: some View {
        if menu == .none {
            cardLink
        } else {
            cardLink.contextMenu { menuItems }
        }
    }

    @ViewBuilder private var cardLink: some View {
        if let directPlay {
            Button(action: directPlay) { cardLabel }
                .buttonStyle(CardFocusStyle(scale: focusScale))
        } else if let destination {
            NavigationLink(destination: destination()) { cardLabel }
                .buttonStyle(CardFocusStyle(scale: focusScale))
        } else {
            NavigationLink { DetailView(type: type, id: id) } label: { cardLabel }
                .buttonStyle(CardFocusStyle(scale: focusScale))
        }
    }

    private var cardLabel: some View {
        legacyCardLabel
    }

    private var legacyCardLabel: some View {
        Group {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Group {
                    if landscape {
                        LandscapeArt(id: id, type: type, title: displayTitle, poster: PosterArtwork.poster(id: id, fallback: displayPoster), width: cardWidth, radius: catalogPrefs.posterRadius.radius)
                    } else {
                        PosterArt(PosterArtwork.poster(id: id, fallback: displayPoster), width: cardWidth, radius: catalogPrefs.posterRadius.radius)
                    }
                }
                    // Vortexo-parity on-card metadata: title + footer over a bottom scrim. Sits directly on
                    // the art; the progress stripe, resume timecode, and watched check layer ABOVE it so those
                    // stay legible (matches Vortexo's z-order in MediaPosterCard). Hidden unless `onCardMeta`
                    // is on and the card has at least rating/year/genre.
                    .overlay(alignment: .bottom) {
                        if showsOnCardMeta {
                            CardMetaOverlay(title: displayTitle, rating: rating, year: year, genres: genres, landscape: landscape)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !isWatched, let progress, progress > 0.01 {
                            ProgressStripe(value: progress).padding(Theme.Space.xs)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let resumeSeconds, let timecode = resumeTimecode(resumeSeconds) {
                            Text(timecode)
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(Theme.Space.sm)
                                .accessibilityLabel("Resumes at \(timecode)")
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2).foregroundStyle(Theme.Palette.accent)
                                .padding(8).shadow(radius: 3)
                                .accessibilityLabel("Watched")
                        }
                    }
                    // Apply the selected radius after every overlay. Clipping only PosterArt above does not
                    // constrain later overlays, so the metadata scrim otherwise paints square bottom corners.
                    .clipShape(RoundedRectangle(cornerRadius: catalogPrefs.posterRadius.radius, style: .continuous))
                    // Vortexo-parity rest shadow: unfocused cards lift off the canvas like Vortexo's
                    // MediaPosterCard (.shadow(black 0.35, radius 8, y: 6)). Focused cards add the ember
                    // glow + depth shadow via CardFocusStyle on top.
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 6)
                    .opacity(isWatched ? 0.55 : 1)
                // Legacy below-card title: hidden when the on-card overlay is showing (avoids duplication),
                // and still respects the user's hidePosterLabels toggle otherwise.
                if !catalogPrefs.hidePosterLabels && !showsOnCardMeta {
                    Text(displayTitle)
                        .font(.system(size: 18, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: cardWidth, alignment: .leading)
                }
            }
            // Read the card as one element so VoiceOver says the title and the resume
            // timecode together, not a stray "1:03" after the title.
            .accessibilityElement(children: .combine)
            .background { if let onFocus { FocusReporter(onFocus: onFocus) } }
            // Pin the focus/long-press interaction region to the card's RESTING rect. Without this,
            // tvOS builds the context-menu preview from the focused card's scaled-up, shadow-offset
            // frame (see CardFocusStyle), which bleeds into the next rail and makes a long-press snap
            // focus to the row below instead of holding the card in place.
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    /// Long-press actions, fired straight at the engine (`CoreBridge.shared`). Continue Watching and the
    /// catalogs both refresh on their own when the engine re-emits the affected fields.
    @ViewBuilder private var menuItems: some View {
        switch menu {
        case .none:
            EmptyView()
        case .continueWatching:
            if let onDetails {
                Button(action: onDetails) {
                    Label("Details", systemImage: "info.circle")
                }
            }
            Button(role: .destructive) {
                CoreBridge.shared.removeFromLibrary(id: id)
            } label: {
                Label("Remove from Continue Watching", systemImage: "minus.circle")
            }
        case .catalog:
            Button {
                CoreBridge.shared.addToLibrary(metaId: id)
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
            }
            Button {
                CoreBridge.shared.setCatalogWatched(metaId: id, true)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                CoreBridge.shared.setCatalogWatched(metaId: id, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "circle")
            }
        case .library:
            Button {
                CoreBridge.shared.setLibraryItemWatched(id: id, true)
            } label: {
                Label("Mark as Watched", systemImage: "checkmark.circle")
            }
            Button {
                CoreBridge.shared.setLibraryItemWatched(id: id, false)
            } label: {
                Label("Mark as Unwatched", systemImage: "circle")
            }
            Button(role: .destructive) {
                CoreBridge.shared.removeFromLibrary(id: id)
            } label: {
                Label("Remove from Library", systemImage: "trash")
            }
        }
    }
}

/// A thin resume-progress bar that sits at the bottom of a poster.
struct ProgressStripe: View {
    let value: Double
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.55))
                Capsule().fill(Theme.Palette.accent).frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

/// A centered empty / not-signed-in / error state: an icon, a title, and a short line.
/// Used instead of an endless spinner when there is genuinely nothing to show.
struct CoreEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var showsSignInButton = false
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager
    @State private var showingLogin = false

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 760)
            if showsSignInButton {
                Button {
                    showingLogin = true
                } label: {
                    Label("Sign In", systemImage: "person.crop.circle")
                }
                .buttonStyle(PrimaryActionStyle())
                .padding(.top, Theme.Space.sm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.screenEdge)
        .fullScreenCover(isPresented: $showingLogin) {
            LoginView(account: account)
        }
    }

    /// The standard "you are not signed in" state, shown on the main tabs.
    static var signedOut: CoreEmptyState {
        CoreEmptyState(
            systemImage: "person.crop.circle.badge.questionmark",
            title: "Sign in to get started",
            message: "Connect a media source or Stremio account to load its library, catalogs, and add-ons. Noiro itself works without a Vortexo account.",
            showsSignInButton: true
        )
    }
}

/// The standard large accent spinner. controlSize(.large) does not exist in
/// older tvOS SDKs (the CI runner's Xcode fails on it), so the size comes from
/// a scale instead, which renders the same everywhere.
struct BigSpinner: View {
    var body: some View {
        ProgressView().scaleEffect(1.5).tint(Theme.Palette.accent)
    }
}

/// Full localized language NAME for an ISO 639 code, so tvOS shows "English", "French", "Italian"
/// rather than bare codes ("en", "fr", "it") like iOS/Mac already do.
///
/// Handles the code shapes that reach us from mpv tracks and add-on tags:
///   - a 2-letter ISO 639-1 code ("en") resolves directly;
///   - a region/script-tagged code ("pt-BR", "zh-Hant") resolves on its base ("pt", "zh");
///   - a 3-letter ISO 639-2 code ("eng", "fre", "ita") is normalized to its 2-letter base via
///     `Locale(identifier:).language.languageCode` first (localizedString(forLanguageCode:) alone
///     returns nil for many 3-letter codes on tvOS, which is what left "ENG"/"FRE"/"ITA" showing).
///
/// Fallback chain never blanks: unknown / und -> "Unknown"; a code the locale database can't name
/// -> its uppercased self. Mirrors the intent of `LanguageIndexClient.displayLabel` but tolerant of
/// 3-letter and region-carrying inputs.
func fullLanguageName(_ code: String) -> String {
    let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty, trimmed != "und", trimmed != "unknown" else { return "Unknown" }
    // Try the raw code as-is first (handles clean 2-letter codes), then fold a region/script-tagged
    // or 3-letter code down to its 2-letter base and try that.
    if let name = Locale.current.localizedString(forLanguageCode: trimmed) { return name.capitalized }
    let base = Locale(identifier: trimmed).language.languageCode?.identifier
        ?? trimmed.split(separator: "-").first.map(String.init)
        ?? trimmed
    if base != trimmed, let name = Locale.current.localizedString(forLanguageCode: base) {
        return name.capitalized
    }
    return trimmed.uppercased()
}
