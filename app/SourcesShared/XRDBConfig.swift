import SwiftUI

/// XRDB (eXtended Ratings DataBase, extendedratings.com / IbbyLabs/XRDB) renders posters and backdrops
/// with rating badges baked in from up to 12 sources (IMDb, TMDB, Rotten Tomatoes, Metacritic,
/// Letterboxd, MDBList, Trakt, SIMKL, MyAnimeList, AniList, Kitsu) plus quality badges (4K/HDR/DV), age
/// rating, genres, and streaming-provider logos. It is an IMAGE service: point Noiro at a self-hosted or
/// hosted instance and it routes poster/backdrop image URLs through `{base}/{type}/{id}?config={alias}`.
/// This is the artwork layer, NOT debrid (the acronym is unrelated to Real-Debrid and friends).
enum XRDB {
    static let baseKey = "noiro.xrdb.baseURL"
    static let aliasKey = "noiro.xrdb.configAlias"
    static let enabledKey = "noiro.xrdb.enabled"

    /// Off until a rights-reviewed Noiro artwork service is approved. A user may
    /// explicitly provide a device-local custom instance.
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }

    static var isEnabled: Bool { enabled && normalizedBase() != nil }

    /// The poster-service image URL for a title, or the `fallback` art when disabled or the id is not
    /// renderable. `type` is "poster", "backdrop", "thumbnail", or "logo". The original poster is passed
    /// as `fb` so the service can fail-soft to it (and so a non-IMDb id gracefully shows the plain poster).
    static func imageURL(_ type: String = "poster", id: String, fallback: String?) -> String? {
        guard enabled, let base = normalizedBase(), let rid = renderableID(id) else { return fallback }
        var url = "\(base)/\(type)/\(rid)"
        let alias = (UserDefaults.standard.string(forKey: aliasKey) ?? "").trimmingCharacters(in: .whitespaces)
        if !alias.isEmpty, let q = alias.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url += "?config=\(q)"
        }
        if let fb = fallback, let e = fb.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url += (url.contains("?") ? "&" : "?") + "fb=\(e)"
        }
        return url
    }

    /// XRDB renders from IMDb (`tt…`) ids directly and from TMDB ids; other id schemes (`kitsu:`, custom
    /// add-on ids) cannot be rendered, so those keep their raw poster.
    private static func renderableID(_ id: String) -> String? {
        if id.hasPrefix("tt") { return id }
        if id.hasPrefix("tmdb:") { return String(id.dropFirst("tmdb:".count)) }
        return nil
    }

    /// There is deliberately no inherited/default hosted renderer.
    static let defaultBase = ""
    private static func normalizedBase() -> String? {
        var s = (UserDefaults.standard.string(forKey: baseKey) ?? "").trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }
}

/// Settings screen for an explicitly user-configured XRDB instance. Its address
/// stays on the device and is excluded from Studio safe settings.
struct XRDBSettingsView: View {
    @AppStorage(XRDB.enabledKey) private var enabled = false
    @AppStorage(XRDB.baseKey) private var baseURL = ""
    @AppStorage(XRDB.aliasKey) private var alias = ""
    @AppStorage(ERDB.enabledKey) private var erdbEnabled = false
    @AppStorage(ERDB.tokenKey) private var erdbToken = ""
    @AppStorage(ERDB.baseKey) private var erdbBase = ""
    @AppStorage(ERDB.fanartPostersKey) private var erdbFanartPosters = false
    @AppStorage(Fanart.enabledKey) private var fanartEnabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                NoiroSettingsPageTitle("Poster artwork & ratings")
                Text("Noiro's hosted artwork service is disabled until its rights review is complete. You can explicitly connect an XRDB-compatible instance you operate or trust; its address stays on this device.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Toggle(isOn: $enabled) {
                    Text("Use a custom XRDB instance")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                field("Custom instance URL", text: $baseURL, hint: "Required when enabled. Use an XRDB-compatible endpoint you operate or trust.", url: true)
                field("Profile alias (optional)", text: $alias, hint: "Only used with a custom instance: the config profile alias from its Configurator.", url: false)

                Text("ERDB (posters + logos)")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("ERDB can render posters, backdrops, and rating-baked logos through an instance you explicitly configure. Its address and token stay on this device.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Toggle(isOn: $erdbEnabled) {
                    Text("Use ERDB (overrides the above)")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                Toggle(isOn: $erdbFanartPosters) {
                    Text("Use fanart posters")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                Text("Pull posters from fanart.tv through your ERDB configuration (requires ERDB and your own fanart key).")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                field("ERDB token (optional)", text: $erdbToken, hint: "Stored only on this device.", url: false)
                field("ERDB base URL", text: $erdbBase, hint: "Required when enabled. Use an instance you operate or trust.", url: true)

                Text("fanart.tv artwork")
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Use community clearlogos from fanart.tv for the hero, INDEPENDENT of ERDB (no rating-baked posters). Uses your fanart.tv key from Metadata keys. More fanart art (clearart, posters, backgrounds) follows.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Toggle(isOn: $fanartEnabled) {
                    Text("Use fanart.tv logos")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Palette.accent)
                .padding(Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .noiroSettingsPageBackground()
    }

    @ViewBuilder private func field(_ title: String, text: Binding<String>, hint: String, url: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            TextField(url ? "https://…" : "alias", text: text)
                .font(.system(size: 15, design: .monospaced))
                .disableAutocorrection(true)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(url ? .URL : .default)
                #endif
            Text(hint).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
