import SwiftUI
import UserNotifications

/// Settings: who you're signed in as, the embedded streaming-server status, subtitles, and app info.
/// Mirrors the official tvOS app's Settings sections, on the StremioX design system.
struct SettingsView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var catalogPrefs = CatalogPreferences.shared
    @ObservedObject private var hdHomeRun = HDHomeRunManager.shared
    @ObservedObject private var sync = NoiroSyncManager.shared
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var launch: NoiroLaunchCoordinator
    @EnvironmentObject private var settings: NoiroSettingsCoordinator
    @State private var serverOnline: Bool?
    @AppStorage("noiro.forceSDRTonemap") private var forceSDRTonemap = false
    @AppStorage("noiro.hdrToneMapMode") private var hdrToneMapMode = "auto"   // auto / on / off
    @State private var showRestartConfirm = false
    /// In-app UI language (tvOS had no picker before). "system" follows the Apple TV language.
    @State private var langSelection: String = AppLanguage.current ?? "system"
    @State private var showLangRestart = false
    // Diagnostic-log export over the LAN: the QR overlay flag + the started (url, qr) payload.
    @State private var showDiagExport = false
    @State private var diagExport: (url: String, qr: Image)?
    @State private var showSyncSettings = false
    @State private var showStremioLogin = false
    @AppStorage("noiro.hideLiveTab") private var hideLiveTab = false
    @AppStorage(LeftTabRailSettings.transparencyKey) private var leftTabTransparency = LeftTabRailSettings.defaultTransparency
    @AppStorage("noiro.home.showCollectionsHub") private var showHubHome = true
    @AppStorage("noiro.home.showUpcoming") private var showUpcomingHome = true   // "Upcoming Episodes"/"Upcoming Movies" rails on Home
    @AppStorage("noiro.collections.refreshCadence") private var hubCadence = "daily"
    @AppStorage("noiro.detail.showFinancials") private var showFinancials = true
    @AppStorage("noiro.detail.showWhereToWatch") private var showWhereToWatch = true
    @AppStorage("noiro.spoilerBlur") private var spoilerBlur = true
    @AppStorage(SeriesDetailSettings.hideSpecialsKey) private var hideSeriesSpecials = false
    // Gemini AI subtitle translation prefs (the key lives in ApiKeys.gemini / Keychain).
    @AppStorage(PlaybackSettings.SubtitleTranslationKey.provider) private var subtitleTranslationProvider = PlaybackSettings.SubtitleTranslationProvider.off.rawValue
    @AppStorage(PlaybackSettings.SubtitleTranslationKey.targetLanguage) private var subtitleTranslationTarget = "en"
    @AppStorage(PlaybackSettings.SubtitleTranslationKey.mode) private var subtitleTranslationMode = PlaybackSettings.SubtitleTranslationMode.whenNeeded.rawValue
    @AppStorage(PlaybackSettings.SubtitleTranslationKey.cachePeriod) private var subtitleTranslationCachePeriod = PlaybackSettings.SubtitleTranslationCachePeriod.days30.rawValue
    @ObservedObject private var apiKeys = ApiKeys.shared   // the Gemini API key field
    @AppStorage(SubtitleStyle.Key.font) private var subFont = SubtitleStyle.defaultFont
    @AppStorage(SubtitleStyle.Key.size) private var subSize = SubtitleStyle.defaultSize
    @AppStorage(SubtitleStyle.Key.sizeScale) private var subSizeScale = 1.0
    @AppStorage(SubtitleStyle.Key.color) private var subColor = SubtitleStyle.defaultColor
    @AppStorage(SubtitleStyle.Key.background) private var subBackground = SubtitleStyle.defaultBackground
    @AppStorage(TrackPreferences.Key.forced) private var prefForced = TrackPreferences.ForcedPolicy.forced.rawValue
    @AppStorage(TrackPreferences.Key.audio) private var prefAudioLang = TrackPreferences.deviceLanguages.first ?? "en"
    @AppStorage(TrackPreferences.Key.subtitle) private var prefSubLang = TrackPreferences.deviceLanguages.first ?? "en"
    // When "1", the audio language chain mirrors the subtitle chain (the audio pickers hide); "0" = independent.
    @AppStorage("noiro.matchAudioSub") private var matchAudioSubRaw = "0"
    @AppStorage(PlaybackSettings.Key.directLinksOnly) private var directLinksOnly = false
    @AppStorage(PlaybackSettings.Key.customMpvOptions) private var customMpvOptions = ""
    @AppStorage(VXProbe.defaultsKey) private var probeLogging = false   // gated diagnostic logging + heartbeat
    @AppStorage(PerformanceMode.overrideKey) private var perfMode = "auto"
    @AppStorage(AudioOutputMode.key) private var audioOutput = AudioOutputMode.auto.rawValue
    @AppStorage(PlaybackSettings.Key.videoUpscaling) private var videoUpscaling = PlaybackSettings.videoUpscaling.rawValue
    // Streaming/seek cache budget, raw byte count (0 = Off, -1 = Unlimited). Int-typed @AppStorage; Int
    // is 64-bit on Apple TV, so the byte budgets are exact.
    @AppStorage(DiskCacheSetting.key) private var diskCacheBytes = 0   // Off by default, matching DiskCacheSetting.storedBytes; the cache is opt-in
    @AppStorage("noiro.seekStep") private var seekStep = "10"   // skip step in seconds, shared with the player
    @AppStorage(PlayerEngineRouter.overrideKey) private var playerEngine = PlayerEngineRouter.Override.auto.rawValue
    @AppStorage(PlayerEngineRouter.dvRemuxKey) private var dvRemux = false   // Dolby Vision for MKV (Beta): in-app remux -> AVPlayer; default OFF
    @AppStorage("noiro.autoSkip") private var autoSkip = false  // auto-skip intro/credits, shared with iOS/Mac
    // Trailer language (D11): the ISO-639-1 code the trailer picker prefers when choosing the YouTube id. Empty
    // = follow the app UI language (the default). Read by TMDBClient.preferredTrailerLanguages / trailerLanguageBaseCode.
    @AppStorage("noiro.trailerLanguage") private var trailerLanguage = ""
    @AppStorage(CommunityTrickplay.settingKey) private var communityTrickplay = true  // share/fetch scrub previews
    // Give-to-get master switch: contribute + consume the whole community data pool. Default ON. Off = out of
    // the pool entirely (no contribute, no consume of any moat feature). See MoatConsent.
    @AppStorage(MoatConsent.key) private var moatContribute = true
    // "Singularity" community source index SERVE opt-in (per device). Default ON; requires sign-in to use.
    @AppStorage(SourceIndexClient.serveKey) private var singularityServe = true
    @AppStorage(SkipTimestampService.providerKey) private var skipProvider = "both"
    @AppStorage(ExternalPlayers.defaultKey) private var defaultExternalPlayer = ""   // "" == built-in libmpv
    // Stremio mirror (account-owns-everything): default OFF = Noiro keeps its own copy of each category;
    // ON = Noiro tracks Stremio (adds and removes) for that category.
    @AppStorage(MirrorSettings.addonsKey) private var mirrorAddons = false
    @AppStorage(MirrorSettings.libraryKey) private var mirrorLibrary = false
    @AppStorage(MirrorSettings.continueWatchingKey) private var mirrorCW = false
    @ObservedObject private var sourcePrefs = SourcePreferences.shared
    @ObservedObject private var pinStore = SourcePinStore.shared
    // Autoplay trailers (the "hero" master switch): the muted autoplay trailer in the featured hero /
    // detail hero. Default ON. SAME key the iOS/Mac view binds. Read by the hero + trailer paths.
    @AppStorage("noiro.autoplayTrailers") private var autoplayTrailers = true
    // Auto-add watched to Library (D8): a title is added to the Library once ~60s of it has played.
    // Default ON. SAME key iOS/Mac binds; read at the 60s progress tick in the player.
    @AppStorage("noiro.autoAddLibrary") private var autoAddLibrary = true
    // Default player volume 0-100 (D5): the level a new playback starts at. The in-player volume slider
    // writes this same key, so the last level persists; this picker sets it explicitly. SAME key as iOS/Mac.
    @AppStorage("noiro.playerVolume") private var playerVolume = 100.0
    // New-episode alerts (F5): a local notification at each upcoming episode's air time. Default ON. SAME key
    // the iOS view's NewEpisodeNotifications.enabledKey resolves to ("noiro.notifyNewEpisodes"); that type
    // lives in a SourcesiOS file the tvOS target does not compile, so tvOS reads the raw key and requests
    // authorization through UNUserNotificationCenter directly (see setNotifyNewEpisodes below).
    @AppStorage("noiro.notifyNewEpisodes") private var notifyNewEpisodes = true
    /// Deterministic Down-chain insurance across the three top account rows so the spatial focus
    /// engine cannot skip Log Out (it stranded far-right before 80fb9d2 and the owner could not reach it).
    private enum AccountFocus: Hashable { case noiro, logOut }
    @FocusState private var accountFocus: AccountFocus?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("Everything in its place, tuned to you.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 350), spacing: Theme.Space.md)],
                        alignment: .leading,
                        spacing: Theme.Space.md
                    ) {
                        profilesSection
                        languageSection
                        accountSection
                        stremioMirrorSection
                        playbackSection
                        notificationsSection
                        streamsSection
                        communitySection
                        serverSection
                        liveTVSection
                        appearanceSection
                        audioSubtitleSection
                        subtitleSection
                        advancedSection
                        backupSection
                        aboutSection
                    }
                }
                .padding(.horizontal, Theme.Space.screenInset)
                .padding(.vertical, Theme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(Color.clear)
        }
        .fullScreenCover(isPresented: $showDiagExport, onDismiss: {
            VXDiagExport.shared.stop()
            diagExport = nil
            settings.endTaskPresentation()
        }) {
            diagExportSheet
        }
        .fullScreenCover(isPresented: $showSyncSettings, onDismiss: {
            settings.endTaskPresentation()
        }) {
            SyncSettingsView()
                .environment(\.noiroSettingsSurface, .standalone)
        }
        .fullScreenCover(isPresented: $showStremioLogin, onDismiss: {
            settings.endTaskPresentation()
        }) {
            LoginView(account: account, initialMode: .stremioLink)
                .environment(\.noiroSettingsSurface, .standalone)
        }
        // Track-language and subtitle-style edits belong to the ACTIVE profile: fold every
        // flat-key change back into it (the captureTheme pattern, RootTabView does the same for
        // the theme). The equality guard inside capturePlayback stops a profile switch's own
        // flat-key writes from echoing back as roster edits.
        .onChange(of: prefAudioLang) { StreamRanking.invalidateCaches(); ProfileStore.shared.capturePlayback() }
        .onChange(of: prefSubLang) { if matchAudioSubRaw == "1", prefAudioLang != prefSubLang { prefAudioLang = prefSubLang }; ProfileStore.shared.capturePlayback() }
        .onChange(of: matchAudioSubRaw) { if matchAudioSubRaw == "1", prefAudioLang != prefSubLang { prefAudioLang = prefSubLang } }
        .onChange(of: prefForced) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subFont) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subSize) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subColor) { ProfileStore.shared.capturePlayback() }
        .onChange(of: subBackground) { ProfileStore.shared.capturePlayback() }
        // Source-ranking taste is per-profile too: the toggle and the up/down reorder mutate
        // SourcePreferences.shared, so fold those into the active profile the same way.
        .onChange(of: sourcePrefs.useAddonOrder) { ProfileStore.shared.capturePlayback() }
        .onChange(of: sourcePrefs.typeOrder) { ProfileStore.shared.capturePlayback() }
        .task {
            // Live server monitor that NEVER gives up. The embedded server cold-starts well after
            // launch on a real Apple TV (node boots while the engine and sync are also busy), and
            // the old 24-second window could expire first, showing "Offline" until a relaunch.
            // Retries fast while offline, keeps the badge fresh once up; restarts on each visit.
            while !Task.isCancelled {
                if effectiveDirectLinksOnly {
                    serverOnline = nil
                    try? await Task.sleep(for: .seconds(12))
                    continue
                }
                let online = await StremioServer.isOnline()
                serverOnline = online
                try? await Task.sleep(for: .seconds(online ? 12 : 3))
            }
        }
    }

    // MARK: Profiles

    private var profilesSection: some View {
        section("Profiles") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(profiles.profiles) { profile in
                        HStack(spacing: 8) {
                            Text(profile.avatar)
                            Text(profile.name)
                            if profile.hasPin { Image(systemName: "lock.fill") }
                            if profile.id == profiles.activeID { Image(systemName: "checkmark.circle.fill") }
                        }
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.vertical, Theme.Space.sm)
                        .background(Theme.Palette.surface2, in: Capsule())
                    }
                    if profiles.profiles.count > 1 {
                        Button {
                            settings.close()
                            DispatchQueue.main.async { profiles.pickedThisLaunch = false }
                        } label: {
                            Label("Switch Profile", systemImage: "person.2.fill")
                        }
                        .buttonStyle(ChipButtonStyle())
                    }
                }
                .padding(.vertical, Theme.Space.xs / 2)
            }
            Link("Manage profiles in Noiro account", destination: URL(string: "https://vortexo.app/account?section=noiro&brand=noiro")!)
                .buttonStyle(ChipButtonStyle(selected: false))
            Text("Create, rename, lock, and remove profiles on the encrypted Noiro dashboard. Profile switching stays in Noiro for playback.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        section(String(localized: "Account")) {
            // The whole account block is one focus section so Down keeps stepping DOWN through its
            // stacked rows instead of leaving after the first hit. Every focusable row (including the
            // Log Out button below) is left-aligned and full-width, so the spatial focus engine's
            // downward beam stays in-column and never skips a row.
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                // Lead with the Noiro account (the app's own E2E account + sync); the Stremio account sits beneath.
                Button {
                    settings.beginTaskPresentation()
                    showSyncSettings = true
                } label: {
                    Label("Noiro Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .focused($accountFocus, equals: .noiro)
                if account.isSignedIn {
                    // Identity is a non-focusable info row; Log Out is its OWN full-width row directly
                    // BELOW it, in the same left-aligned column as every other account row. The old layout
                    // stranded Log Out far-right after a Spacer(), so the spatial focus engine's downward
                    // beam from the left-aligned rows missed it and the owner could not reach it on tvOS.
                    // Stacking it in-column makes it a deterministic D-pad target (down lands on it, then
                    // continues to the rows below). The .focusSection() on the enclosing VStack stays.
                    HStack(spacing: Theme.Space.md) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 52)).foregroundStyle(Theme.Palette.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.email ?? "Signed in").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                            Text("Stremio · \(account.addons.count) add-ons · \(account.streamAddonBases.count) stream sources")
                                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    Button { account.signOut(); core.logOut() } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($accountFocus, equals: .logOut)
                } else {
                    Button {
                        settings.beginTaskPresentation()
                        showStremioLogin = true
                    } label: {
                        Label("Sign in to your Stremio account", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(PrimaryActionStyle())
                }
                NavigationLink { XRDBSettingsView() } label: {
                    Label("Poster artwork (ERDB, ratings)", systemImage: "star.circle")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                NavigationLink { MetadataKeysView() } label: {
                    Label("Metadata API keys", systemImage: "key.fill")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                Link("Manage Noiro account", destination: URL(string: "https://vortexo.app/account?section=noiro&brand=noiro")!)
                    .buttonStyle(ChipButtonStyle(selected: false))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
    }

    // MARK: Stremio mirror

    /// Per-category control of whether Noiro mirrors a connected Stremio account. Off (the default) keeps
    /// a Noiro copy of each category so a Stremio removal never removes it from Noiro; On makes Noiro
    /// track Stremio (adds and removes) for that category. Hydration always keeps the Noiro-owned set
    /// alive even when signed out of Stremio, independent of these.
    @ViewBuilder private var stremioMirrorSection: some View {
        section(String(localized: "Stremio mirror")) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                choiceRow(String(localized: "Two-way sync add-ons with Stremio"), [("0", "Off"), ("1", "On")],
                          selection: Binding(get: { mirrorAddons ? "1" : "0" }, set: { mirrorAddons = ($0 == "1") }))
                choiceRow(String(localized: "Mirror library from Stremio"), [("0", "Off"), ("1", "On")],
                          selection: Binding(get: { mirrorLibrary ? "1" : "0" }, set: { mirrorLibrary = ($0 == "1") }))
                choiceRow(String(localized: "Mirror Continue Watching from Stremio"), [("0", "Off"), ("1", "On")],
                          selection: Binding(get: { mirrorCW ? "1" : "0" }, set: { mirrorCW = ($0 == "1") }))
                Text("Off (recommended) is one-way: Noiro pulls in your Stremio add-ons but never edits your Stremio account, so removing an add-on in Noiro hides it here only and leaves your Stremio account untouched. On is two-way: adding or removing an add-on in Noiro also adds or removes it in your Stremio account. Your add-ons, library, and Continue Watching always stay even when you are signed out of Stremio.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
    }

    // MARK: Playback

    private var playbackSection: some View {
        section("Playback") {
            if PlaybackSettings.directLinksOnlyForced {
                directLinksOnlyRow
                    .background(Theme.Palette.surface1,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            } else {
                Button { setDirectLinksOnly(!directLinksOnly) } label: {
                    directLinksOnlyRow
                }
                .buttonStyle(RowFocusStyle())
            }
            choiceRow(String(localized: "Audio output"), AudioOutputMode.allCases.map { ($0.rawValue, $0.label) }, selection: $audioOutput)
            Text(AudioOutputMode(rawValue: audioOutput)?.detail ?? "")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Video upscaling"), VideoUpscaling.allCases.map { ($0.rawValue, $0.label) }, selection: $videoUpscaling)
            Text(VideoUpscaling(rawValue: videoUpscaling)?.detail ?? "")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Streaming cache"),
                      DiskCacheSetting.pickerOptions.map { (String($0.id), $0.label) },
                      selection: Binding(get: { String(diskCacheBytes) },
                                         set: { diskCacheBytes = Int($0) ?? Int(DiskCacheSetting.defaultBytes) }))
            Text(diskCacheFooter)
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Player engine"), PlayerEngineRouter.Override.allCases.map { ($0.rawValue, $0.label) }, selection: $playerEngine)
            Text("Auto plays HLS and Dolby Vision through AVPlayer (AirPlay and Picture in Picture), with the full player controls, and uses the built-in libmpv player for torrents, MKV, and anything AVPlayer cannot open. If a stream will not start, choose Always libmpv.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Dolby Vision for MKV (Beta)"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { dvRemux ? "1" : "0" }, set: { dvRemux = ($0 == "1") }))
            Text("Plays Dolby Vision .mkv from debrid via an in-app remux. Experimental; falls back automatically if it fails.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Skip step"), [("10", "10s"), ("15", "15s"), ("30", "30s")], selection: $seekStep)
            choiceRow(String(localized: "Auto-skip intro & credits"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { autoSkip ? "1" : "0" }, set: { autoSkip = ($0 == "1") }))
            choiceRow(String(localized: "Skip timestamps source"), [("theintrodb", "TheIntroDB"), ("skipdb", "SkipDB"), ("both", "Both")],
                      selection: $skipProvider)
            NavigationLink { SkipKeysView() } label: {
                Label("Skip database key", systemImage: "checkmark.bubble")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            // Autoplay trailers: the master switch for the muted autoplay trailer in the featured hero /
            // detail hero (the "hero" setting). Default ON. SAME key iOS/Mac binds.
            choiceRow(String(localized: "Autoplay trailers"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { autoplayTrailers ? "1" : "0" }, set: { autoplayTrailers = ($0 == "1") }))
            Text("Play a muted trailer automatically in the featured hero and on a title's detail page.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            // Trailer language (D11): the language the trailer picker prefers when choosing the YouTube id.
            // "App language" (the empty tag, the default) follows the app UI language; a set value becomes the
            // highest-priority trailer language in TMDBClient.preferredTrailerLanguages. Mirrors iOS/Mac.
            choiceRow(String(localized: "Trailer language"), trailerLanguageOptions, selection: $trailerLanguage)
            choiceRow(String(localized: "Play in"), externalPlayerChoices, selection: $defaultExternalPlayer)
            Text("Direct and debrid streams open in your chosen player automatically. Torrents and the built-in player are unaffected.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            NavigationLink { SeekBarStylePicker() } label: {
                Label("Seek bar style", systemImage: "slider.horizontal.below.rectangle")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            choiceRow(String(localized: "Community scrub previews"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { communityTrickplay ? "1" : "0" }, set: { communityTrickplay = ($0 == "1") }))
            Text("Share and reuse scrub-preview thumbnails across the community, so previews appear instantly without each device regenerating them. Only the generated thumbnails are shared, never any account data.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            // Default player volume (D5): the level a new playback starts at. The in-player volume slider
            // writes the same key, so this also reflects the last level used. Coarse 0/25/50/75/100 steps,
            // plus the exact current level as its own chip when the in-player slider left it off-step (e.g.
            // 60%), so the picker never snap-misreports the real starting level. SAME key as iOS/Mac.
            choiceRow(String(localized: "Default volume"), playerVolumeOptions,
                      selection: Binding(get: { String(Int(playerVolume.rounded())) },
                                         set: { playerVolume = Double(Int($0) ?? 100) }))
            // Auto-add a title to the Library once ~60s of it has played (D8). Default ON. The engine adds it
            // through the account library on the main profile; overlay profiles are skipped. SAME key as iOS/Mac.
            choiceRow(String(localized: "Auto-add watched to Library"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { autoAddLibrary ? "1" : "0" }, set: { autoAddLibrary = ($0 == "1") }))
            Text("Adds a title to your Library once about a minute of it has played, so it is easy to find again.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Coarse 0/25/50/75/100 volume steps, plus the exact current level as its own chip when the in-player
    /// fine slider left `stremiox.playerVolume` off-step (e.g. 60), so the picker shows the real value
    /// instead of snapping it to a wrong neighbour. Mirrors the iOS `playerVolumeSteps`.
    private var playerVolumeOptions: [(id: String, label: String)] {
        let steps = [0, 25, 50, 75, 100]
        let current = Int(playerVolume.rounded())
        let all = steps.contains(current) ? steps : (steps + [current]).sorted()
        return all.map { (id: String($0), label: $0 == 100 ? String(localized: "Max (100%)") : "\($0)%") }
    }

    // MARK: Notifications

    /// New-episode alerts (F5). Same key + behavior as the iOS view: enabling requests notification
    /// authorization and settles the stored flag to the real grant; disabling clears pending alerts.
    private var notificationsSection: some View {
        section(String(localized: "Notifications")) {
            choiceRow(String(localized: "New episode alerts"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { notifyNewEpisodes ? "1" : "0" },
                                         set: { setNotifyNewEpisodes($0 == "1") }))
            Text("Get a notification when a new episode of a series you open is about to air. Scheduled on-device for upcoming episodes, so no background tracking is needed.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Turn new-episode alerts on/off. Enabling asks the system for permission and stores the real grant (a
    /// denial settles the flag back off); disabling clears the flag and every pending alert. This mirrors
    /// `NewEpisodeNotifications.setEnabled`, inlined here because that type lives in a SourcesiOS file the
    /// tvOS target does not compile. The SAME `stremiox.notifyNewEpisodes` key is written either way.
    private func setNotifyNewEpisodes(_ on: Bool) {
        guard on else {
            notifyNewEpisodes = false
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            return
        }
        Task { @MainActor in
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            notifyNewEpisodes = granted
        }
    }

    /// Give-to-get master switch + the opt-in "Singularity" community source index. The master toggle
    /// governs whether this device both contributes anonymized metadata AND consumes every pooled feature;
    /// off = out of the whole pool. Singularity SERVE is a further per-device opt-in that also needs sign-in.
    private var communitySection: some View {
        section(String(localized: "Community")) {
            choiceRow(String(localized: "Contribute anonymized data to improve results"),
                      [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { moatContribute ? "1" : "0" }, set: { moatContribute = ($0 == "1") }))
            Text(MoatConsent.disclosure)
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            Text("Community source services remain disabled until their rights and privacy review is complete. This choice does not upload playback URLs, credentials, server addresses, or media.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Built-in plus every curated external player; picking one auto-hands eligible streams to it.
    private var externalPlayerChoices: [(String, String)] {
        [("", "Built-in player")] + ExternalPlayers.menu().map { ($0.id, $0.name) }
    }

    /// Explains the streaming cache and shows live on-disk usage when on. On the Apple TV HD the cache
    /// is additionally capped tight; Unlimited is always bounded to half of free storage and cleared
    /// when a title finishes, so it never fills the device.
    private var diskCacheFooter: String {
        let base = String(localized: "A bigger streaming cache buffers more video on disk so you can seek minutes ahead without re-buffering. Unlimited is still capped to half your free storage and the cache clears when a title finishes, so it never fills your Apple TV.")
        guard diskCacheBytes != 0 else { return base }
        // currentUsageBytes sums the on-disk mpv-cache dir, which stays EMPTY on this MPVKit build (the
        // buffer is RAM-resident, not offloaded to disk), so it always read "0 KB" and looked broken. Show
        // the real RAM-bounded budget the player will actually use instead (floored at 64 MiB, clamped to
        // the device-safe ceiling), which is an honest non-zero number visible in Settings.
        let budget = DiskCacheSetting.humanReadable(DiskCacheSetting.resolvedMaxBytes())
        return base + " " + String(localized: "Cache budget: \(budget).")
    }

    private var effectiveDirectLinksOnly: Bool {
        PlaybackSettings.directLinksOnly
    }

    private var directLinksOnlyRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Direct Links Only")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(PlaybackSettings.directLinksOnlyForced
                     ? "This build does not bundle the torrent engine. Only direct and debrid links can play."
                     : "Hide torrent and magnet sources. Only direct and debrid links will play.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.md)
            if PlaybackSettings.directLinksOnlyForced {
                UnavailableBadge(text: "Not bundled")
            } else {
                TogglePill(isOn: effectiveDirectLinksOnly)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func setDirectLinksOnly(_ value: Bool) {
        directLinksOnly = value
        #if !STREMIOX_NO_EMBEDDED_SERVER
        if !value, !ProcessInfo.processInfo.arguments.contains("-stremiox-no-server") {
            NodeServer.startIfNeeded()
        }
        #endif
    }

    // MARK: Streaming server

    private var serverSection: some View {
        section("Streaming Server") {
            HStack(spacing: Theme.Space.sm) {
                Circle().fill(serverColor).frame(width: 16, height: 16)
                Text(serverText).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(serverBadgeText)
                    .font(Theme.Typography.eyebrow).tracking(1)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.Palette.surface3, in: Capsule())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            if effectiveDirectLinksOnly {
                Text(PlaybackSettings.directLinksOnlyForced
                     ? "This build does not bundle the streaming server."
                     : "Direct Links Only is enabled, so torrent streaming and server configuration are inactive.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(StremioServer.base)
                    .font(.system(size: 18, design: .monospaced)).foregroundStyle(Theme.Palette.textTertiary)
                // When the embedded server is unreachable, explain itself: node's run state and the
                // server's own last log lines, so a dead server is diagnosable from the couch.
                if serverOnline == false && !StremioServer.isCustom {
                    #if !STREMIOX_NO_EMBEDDED_SERVER
                    Text(NodeServer.statusDescription)
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    ForEach(NodeServer.logTail(), id: \.self) { line in
                        Text(line).font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textTertiary).lineLimit(1)
                    }
                    #endif
                }
                // Apple TV has no user-facing force quit, and a dead embedded server can
                // only come back with a fresh process (node starts once per process).
                Button { showRestartConfirm = true } label: {
                    Label("Restart App", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(ChipButtonStyle())
                .confirmationDialog("Restart Noiro?", isPresented: $showRestartConfirm, titleVisibility: .visible) {
                    Button("Quit Now", role: .destructive) {
                        DiagnosticsLog.logSync("app", "user requested app restart from Settings")
                        exit(0)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The app quits immediately. Open it again from the Home Screen; the streaming server restarts with it.")
                }
                NavigationLink {
                    ServerConfigView { Task { serverOnline = await StremioServer.isOnline() } }
                } label: {
                    Label("Configure server", systemImage: "server.rack")
                }
                .buttonStyle(PrimaryActionStyle())
            }
        }
    }

    private var serverColor: Color {
        if effectiveDirectLinksOnly { return Theme.Palette.textTertiary }
        switch serverOnline {
        case .some(true): return Color(.sRGB, red: 0.45, green: 0.72, blue: 0.42)
        case .some(false): return Theme.Palette.danger
        default: return Theme.Palette.accent
        }
    }

    // MARK: Live TV tuner

    private var liveTVSection: some View {
        section("Live TV") {
            choiceRow("Show Live TV tab", [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { hideLiveTab ? "0" : "1" },
                                         set: { hideLiveTab = ($0 == "0") }))

            choiceRow("HDHomeRun", [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { hdHomeRun.enabled ? "1" : "0" },
                                         set: { hdHomeRun.enabled = ($0 == "1") }))

            TextField("HDHomeRun IP or hostname", text: $hdHomeRun.address)
                .textContentType(.URL)
            TextField("HDHomeRun guide account email (optional)", text: $hdHomeRun.guideEmail)
                .textContentType(.emailAddress)

            HStack(spacing: Theme.Space.md) {
                Button {
                    Task { await hdHomeRun.discover() }
                } label: {
                    Label(hdHomeRun.isDiscovering ? "Discovering…" : "Discover tuner",
                          systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(hdHomeRun.isDiscovering)

                if hdHomeRun.device != nil {
                    Button {
                        Task { await hdHomeRun.refreshChannels() }
                    } label: {
                        Label("Refresh channels", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .disabled(hdHomeRun.isDiscovering)

                    Button {
                        Task { await hdHomeRun.refreshGuide() }
                    } label: {
                        Label("Refresh guide", systemImage: "calendar.badge.clock")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .disabled(hdHomeRun.isDiscovering)

                    Button(role: .destructive) { hdHomeRun.clear() } label: {
                        Label("Forget tuner", systemImage: "trash")
                    }
                    .buttonStyle(ChipButtonStyle(selected: false))
                }
            }

            Text(hdHomeRun.status)
                .font(Theme.Typography.label)
                .foregroundStyle(hdHomeRun.device == nil ? Theme.Palette.textSecondary : Theme.Palette.accent)
            Text("Noiro discovers an HDHomeRun on your home network, saves its lineup and guide, and adds current programs to the Live TV tab. Enter the tuner IP if your router does not resolve hdhomerun.local. Guide artwork and program information require HDHomeRun guide access; if the tuner does not publish DeviceAuth, enter the email linked to that guide account.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var serverText: String {
        if effectiveDirectLinksOnly { return "Disabled by Direct Links Only" }
        switch serverOnline { case .some(true): return "Online"; case .some(false): return "Offline"; default: return "Checking…" }
    }
    private var serverBadgeText: String {
        if effectiveDirectLinksOnly {
            return PlaybackSettings.directLinksOnlyForced ? "NOT BUNDLED" : "DISABLED"
        }
        return StremioServer.isCustom ? "CUSTOM" : "EMBEDDED"
    }

    // MARK: Appearance (accent + chrome)

    /// "App language" (the empty tag = follow the app UI language) + every shipped language, for the Trailer
    /// language picker (D11). Distinct from `appLanguageOptions`: the empty tag matches the `stremiox.trailerLanguage`
    /// unset convention (`TMDBClient.trailerLanguageOverride` treats empty as unset), mirroring iOS/Mac.
    private var trailerLanguageOptions: [(id: String, label: String)] {
        [(id: "", label: String(localized: "App language"))] + AppLanguage.supported.map { (id: $0.code, label: $0.name) }
    }

    /// "System Default" + every shipped language, for the App Language picker on tvOS.
    private var appLanguageOptions: [(id: String, label: String)] {
        [(id: "system", label: "System Default")] + AppLanguage.supported.map { (id: $0.code, label: $0.name) }
    }

    private var languageSection: some View {
        section("Language") {
            choiceRow(String(localized: "App Language"), appLanguageOptions, selection: Binding(
                get: { langSelection },
                set: { newValue in
                    langSelection = newValue
                    AppLanguage.set(newValue == "system" ? nil : newValue)
                    showLangRestart = true
                }))
            Text("Switches the whole app to this language. Noiro must quit and reopen to apply it.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .confirmationDialog("Apply language?", isPresented: $showLangRestart, titleVisibility: .visible) {
            Button("Quit Now", role: .destructive) {
                DiagnosticsLog.logSync("app", "user requested app restart to apply language")
                exit(0)
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Noiro needs to quit and reopen to display the app in the new language. Open it again from the Home Screen.")
        }
    }

    private var appearanceSection: some View {
        section("Appearance") {
            ThemeAccentPicker(selection: $theme.accentID).focusSection()
            ThemeBackgroundPicker(oled: $theme.oled).focusSection()
            Text("Accent recolors focus, selection, and progress across the app. OLED Black uses true black, best on AMOLED panels.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Left tab transparency"),
                      leftTabTransparencyOptions,
                      selection: $leftTabTransparency)
            Text("Controls how much of the page shows through the custom Left Tab. 0% is solid black and 100% removes its background.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Cinematic catalog cards"), [("1", "Landscape"), ("0", "Portrait")],
                      selection: Binding(get: { catalogPrefs.landscapeCards ? "1" : "0" }, set: { catalogPrefs.landscapeCards = ($0 == "1") }))
            Text("Show catalog posters as wide cinematic cards using clean TMDB artwork. Choose Portrait for the classic poster grid.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Text on cards"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { catalogPrefs.onCardMeta ? "1" : "0" }, set: { catalogPrefs.onCardMeta = ($0 == "1") }))
            Text("Show titles and available details directly over poster artwork.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Standalone hide-labels toggle (SAME key as the Poster Style screen's toggle), surfaced here so
            // it is discoverable without opening Poster style. Applies across every poster rail.
            choiceRow(String(localized: "Hide poster labels"), [("1", "Hide"), ("0", "Show")],
                      selection: Binding(get: { catalogPrefs.hidePosterLabels ? "1" : "0" }, set: { catalogPrefs.hidePosterLabels = ($0 == "1") }))
            NavigationLink { TVPosterStyleView() } label: {
                Label("Poster style", systemImage: "rectangle.portrait.on.rectangle.portrait")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            Text("Tune poster width, corner radius, landscape 16:9 art, and labels, with a live preview.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Collections on Home"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showHubHome ? "1" : "0" }, set: { showHubHome = ($0 == "1") }))
            choiceRow(String(localized: "Upcoming on Home"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showUpcomingHome ? "1" : "0" }, set: { showUpcomingHome = ($0 == "1") }))
            Text("Hide the Upcoming Episodes and Upcoming Movies rails on Home if you do not use them.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            choiceRow(String(localized: "Refresh collections"), [("daily", "Daily"), ("twiceDaily", "Twice"), ("fourTimesDaily", "4x")],
                      selection: $hubCadence)
            NavigationLink { TVReorderServicesView() } label: {
                Label("Streaming services", systemImage: "rectangle.stack.badge.plus")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            NavigationLink { TVDiscoverSettingsView() } label: {
                Label("Discover & region", systemImage: "globe")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            Text("Discover cards, Streaming-service tiles, and Genre tiles on Home; tap a tile to browse its catalogs (Movies, Shows, New, Top week/month/year, Trending). Needs a TMDB key.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Budget & box office"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showFinancials ? "1" : "0" }, set: { showFinancials = ($0 == "1") }))
            Text("Show a movie's budget, box office, and profit on its detail page. Movies only; needs a TMDB key.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Where to Watch"), [("1", "Show"), ("0", "Hide")],
                      selection: Binding(get: { showWhereToWatch ? "1" : "0" }, set: { showWhereToWatch = ($0 == "1") }))
            Text("Show legal streaming providers available in your region on detail pages.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Blur unwatched episodes"), [("1", "Blur"), ("0", "Show")],
                      selection: Binding(get: { spoilerBlur ? "1" : "0" }, set: { spoilerBlur = ($0 == "1") }))
            Text("Blur episode thumbnails you have not watched yet, to avoid spoilers.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Specials / Season 0"), [("0", "Show"), ("1", "Hide")],
                      selection: Binding(get: { hideSeriesSpecials ? "1" : "0" }, set: { hideSeriesSpecials = ($0 == "1") }))
            Text("Hide Specials from series detail pages and skip Season 0 when choosing Play, Resume, or the next episode.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Dolby Vision / HDR"), [("auto", "Auto"), ("on", "Tone-map to SDR"), ("off", "Always HDR")], selection: $hdrToneMapMode)
            Text("Auto tone-maps HDR and Dolby Vision to SDR only on a TV that can't show HDR. Choose Tone-map to SDR if 4K Dolby Vision remuxes look washed out, green or purple on your TV; Always HDR forces pass-through.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            stepperRow(String(localized: "App text size"), value: theme.textScale,
                       range: ThemeManager.textScaleRange,
                       onMinus: { theme.adjustTextScale(-1) },
                       onPlus: { theme.adjustTextScale(1) })
            Text("Makes every screen's text larger or smaller. Changes apply instantly.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            choiceRow(String(localized: "Performance"), [("auto", "Auto"), ("full", "Full"), ("reduced", "Reduced")], selection: $perfMode)
            Text("Auto keeps the full experience on capable Apple TVs and switches to a lighter one on older models like the Apple TV HD. Reduced trims animations and shrinks playback buffers so the remote stays responsive on weak hardware. Restart the app after changing this.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Stream source preferences

    private var streamsSection: some View {
        section("Streams") {
            NavigationLink { DebridKeysView() } label: {
                Label("Debrid API keys", systemImage: "key.horizontal.fill")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Quality preset")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                HStack(spacing: Theme.Space.md) {
                    ForEach(SourcePreset.allCases) { preset in
                        Button(preset.label) { sourcePrefs.apply(preset) }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
                Text("A one-tap starting point; fine-tune the controls below. Your source-type order saves per profile.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            .focusSection()
            Toggle(isOn: $sourcePrefs.useAddonOrder) {
                Text("Use add-on ranking order")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)
            Text("When on, streams appear in the order your add-ons return them. Useful if you use a ranking add-on like AIOStreams. When off, the app's own ranking applies.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            if !sourcePrefs.useAddonOrder {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Source type priority")
                        .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    ForEach(Array(sourcePrefs.typeOrder.enumerated()), id: \.element) { index, sourceType in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sourceType.label)
                                    .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textPrimary)
                                Text(sourceType.detail)
                                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                Button {
                                    sourcePrefs.moveType(at: index, direction: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(ChipButtonStyle(selected: false))
                                .opacity(index == 0 ? 0.3 : 1)
                                .disabled(index == 0)
                                Button {
                                    sourcePrefs.moveType(at: index, direction: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(ChipButtonStyle(selected: false))
                                .opacity(index == sourcePrefs.typeOrder.count - 1 ? 0.3 : 1)
                                .disabled(index == sourcePrefs.typeOrder.count - 1)
                            }
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                }
                .focusSection()
                Text("Sources matching the top type are ranked first within each quality tier. Debrid and Usenet are always instant; Torrent streams require peer availability.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            choiceRow(String(localized: "Safety filter"), [("off", "Off"), ("balanced", "Balanced"), ("strict", "Strict")], selection: $sourcePrefs.safetyMode)
            Text(sourcePrefs.keywordsAreRegex
                 ? "Hides CAM and fake-quality sources. Hide / Require words are case-insensitive regex patterns (an invalid pattern is ignored)."
                 : "Hides CAM and fake-quality sources. Hide / Require words filter the list by name (comma-separated).")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Space.md) {
                Text("Hide words").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                TextField("none", text: $sourcePrefs.excludeKeywords)
            }
            HStack(spacing: Theme.Space.md) {
                Text("Require words").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                TextField("none", text: $sourcePrefs.includeKeywords)
            }
            Toggle(isOn: $sourcePrefs.keywordsAreRegex) {
                Text("Match words as regex")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(Theme.Palette.accent)
            choiceRow(String(localized: "Max file size"),
                      [(0.0, "Off"), (2.0, "2 GB"), (5.0, "5 GB"), (10.0, "10 GB"),
                       (15.0, "15 GB"), (20.0, "20 GB"), (30.0, "30 GB"), (50.0, "50 GB")],
                      selection: $sourcePrefs.maxFileSizeGB)
            Text("Hides sources larger than the cap (e.g. 1080p but not a 20 GB file). Sources with no stated size are kept.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Instant / dead-torrent / HDR / AV1 / max-quality filters (SAME SourcePreferences properties the
            // iOS/Mac view binds), ported to the focus-driven choiceRow style.
            choiceRow(String(localized: "Instant sources only"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { sourcePrefs.instantOnly ? "1" : "0" }, set: { sourcePrefs.instantOnly = ($0 == "1") }))
            choiceRow(String(localized: "Hide dead torrents"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { sourcePrefs.hideDeadTorrents ? "1" : "0" }, set: { sourcePrefs.hideDeadTorrents = ($0 == "1") }))
            choiceRow(String(localized: "HDR sources only"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { sourcePrefs.hdrOnly ? "1" : "0" }, set: { sourcePrefs.hdrOnly = ($0 == "1") }))
            choiceRow(String(localized: "Hide AV1 sources"), [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { sourcePrefs.excludeAV1 ? "1" : "0" }, set: { sourcePrefs.excludeAV1 = ($0 == "1") }))
            choiceRow(String(localized: "Max quality"),
                      [("0", String(localized: "Unlimited")), ("4000", "4K"), ("1080", "1080p"), ("720", "720p")],
                      selection: Binding(get: { String(sourcePrefs.maxResolution) }, set: { sourcePrefs.maxResolution = Int($0) ?? 0 }))
            Text("Instant hides torrents that are not cached on your debrid service. Max quality caps the resolution shown. Hide dead torrents drops sources with no seeders.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Pinned sources: long-press a source on any title to pin it; this clears them all. Shown only
            // when there is something to clear (SAME SourcePinStore the iOS/Mac view uses).
            if pinStore.pinnedCount > 0 {
                Button { pinStore.clearAll() } label: {
                    Label("Clear pinned sources (\(pinStore.pinnedCount))", systemImage: "pin.slash")
                }
                .buttonStyle(ChipButtonStyle(selected: true, accent: Theme.Palette.danger, accentText: Theme.Palette.danger))
            }
        }
    }

    // MARK: Audio & subtitle preferences

    private var audioSubtitleSection: some View {
        section("Audio & Subtitles") {
            choiceRow(String(localized: "Match audio to subtitle languages"), [("0", "Off"), ("1", "On")], selection: $matchAudioSubRaw)
            if matchAudioSubRaw != "1" {
                choiceRow(String(localized: "Audio language"), TrackPreferences.commonLanguages, selection: primaryAudioLang)
                choiceRow(String(localized: "Fallback audio language"),
                          [(id: "", label: String(localized: "None"))] + TrackPreferences.commonLanguages,
                          selection: fallbackAudioLang)
            }
            choiceRow(String(localized: "Subtitle language"), TrackPreferences.commonLanguages, selection: primarySubLang)
            choiceRow(String(localized: "Fallback subtitle language"),
                      [(id: "", label: String(localized: "None"))] + TrackPreferences.commonLanguages,
                      selection: fallbackSubLang)
            choiceRow(String(localized: "Subtitles"), TrackPreferences.ForcedPolicy.allCases.map { ($0.rawValue, $0.label) }, selection: $prefForced)
            Text("The player auto-picks these when a title starts. Each language falls back to your second choice when a title has none in the first. Turn on Match audio to subtitle languages to drive both from one list. Forced shows only foreign-dialogue captions; Always shows full subtitles in your language. Foreign-language titles always get full subtitles so you can follow.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)

            // Gemini AI subtitle translation: translate the on-screen subtitle to a target language.
            // The provider toggle gates the whole feature; without a Gemini key the pickers are inert.
            choiceRow(String(localized: "Translate subtitles"),
                      PlaybackSettings.SubtitleTranslationProvider.allCases.map { ($0.rawValue, $0.label) },
                      selection: $subtitleTranslationProvider)
            if subtitleTranslationProvider == PlaybackSettings.SubtitleTranslationProvider.gemini.rawValue {
                choiceRow(String(localized: "Translate to"),
                          SubtitleTranslationLanguage.pickerOptions,
                          selection: $subtitleTranslationTarget)
                choiceRow(String(localized: "Translate when"),
                          PlaybackSettings.SubtitleTranslationMode.allCases.map { ($0.rawValue, $0.label) },
                          selection: $subtitleTranslationMode)
                choiceRow(String(localized: "Keep translated subtitles"),
                          PlaybackSettings.SubtitleTranslationCachePeriod.allCases.map { ($0.rawValue, $0.label) },
                          selection: $subtitleTranslationCachePeriod)
                Text("Gemini translates the selected subtitle into this language during playback. When needed skips tracks already in your language; Always translates every track. Cached translations are kept for the selected period after their most recent use, so repeat plays are free. Unlimited keeps them until the app is removed or its data is cleared.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
            // The Gemini API key (Keychain-backed via ApiKeys.gemini). Get one free at aistudio.google.com.
            TextField("Paste Gemini API key", text: $apiKeys.gemini)
                .autocorrectionDisabled()
            Text("Noiro does not include a Gemini key. Get a free one at aistudio.google.com (API key) and paste it here. The key is stored in the device Keychain.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// The stored subtitle preference (`TrackPreferences.Key.subtitle`) is a comma-separated PRIORITY LIST
    /// ("tr,en") that TrackSelector already walks in order; the UI presents it as two pickers via these
    /// derived bindings. Primary = the first entry; setting it keeps the existing fallback (dropping it only
    /// when it would duplicate the new primary). The raw `prefSubLang` @AppStorage stays the storage anchor,
    /// so profile capture (.onChange(of: prefSubLang)) and cross-device sync round-trip the whole list.
    private var primarySubLang: Binding<String> {
        Binding(
            get: { prefSubLang.split(separator: ",").first.map(String.init) ?? "en" },
            set: { newPrimary in
                let parts = prefSubLang.split(separator: ",").map(String.init)
                let fallback = parts.count > 1 ? parts[1] : ""
                prefSubLang = (fallback.isEmpty || fallback == newPrimary) ? newPrimary : "\(newPrimary),\(fallback)"
            })
    }

    /// Fallback = the second entry of the stored chain ("" = none). Choosing None (or the primary itself)
    /// stores just the primary.
    private var fallbackSubLang: Binding<String> {
        Binding(
            get: {
                let parts = prefSubLang.split(separator: ",").map(String.init)
                return parts.count > 1 ? parts[1] : ""
            },
            set: { newFallback in
                let primary = prefSubLang.split(separator: ",").first.map(String.init) ?? "en"
                prefSubLang = (newFallback.isEmpty || newFallback == primary) ? primary : "\(primary),\(newFallback)"
            })
    }

    /// Audio primary / fallback: the SAME two-picker derivation as the subtitle chain, over the
    /// `TrackPreferences.Key.audio` list. Shown only when "Match audio to subtitle languages" is off.
    private var primaryAudioLang: Binding<String> {
        Binding(
            get: { prefAudioLang.split(separator: ",").first.map(String.init) ?? "en" },
            set: { newPrimary in
                let parts = prefAudioLang.split(separator: ",").map(String.init)
                let fallback = parts.count > 1 ? parts[1] : ""
                prefAudioLang = (fallback.isEmpty || fallback == newPrimary) ? newPrimary : "\(newPrimary),\(fallback)"
            })
    }

    private var fallbackAudioLang: Binding<String> {
        Binding(
            get: {
                let parts = prefAudioLang.split(separator: ",").map(String.init)
                return parts.count > 1 ? parts[1] : ""
            },
            set: { newFallback in
                let primary = prefAudioLang.split(separator: ",").first.map(String.init) ?? "en"
                prefAudioLang = (newFallback.isEmpty || newFallback == primary) ? primary : "\(primary),\(newFallback)"
            })
    }

    // MARK: Subtitle style

    private var subtitleSection: some View {
        section("Subtitle Style") {
            choiceRow(String(localized: "Font"), SubtitleStyle.fonts.map { ($0.id, $0.label) }, selection: $subFont)
            choiceRow(String(localized: "Size"), SubtitleStyle.sizes.map { ($0.id, $0.label) }, selection: $subSize)
            stepperRow(String(localized: "Fine size"), value: subSizeScale,
                       range: SubtitleStyle.sizeScaleRange,
                       onMinus: { adjustSubScale(-1) },
                       onPlus: { adjustSubScale(1) })
            choiceRow(String(localized: "Color"), SubtitleStyle.colors.map { ($0.id, $0.label) }, selection: $subColor)
            choiceRow("Background", SubtitleStyle.backgrounds.map { ($0.id, $0.label) }, selection: $subBackground)
            Text("Styles the built-in player's subtitles. Pick which subtitle track to show from the player while watching.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: Advanced (mpv options)

    private var advancedSection: some View {
        section("Advanced (mpv options)") {
            Text("For power users; one option=value per line. Applied on top of Noiro's defaults the next time a video starts.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            TextField("profile=gpu-hq", text: $customMpvOptions, axis: .vertical)
                .lineLimit(3...10)
                .autocorrectionDisabled(true)
                .focusSection()
            // Gated diagnostic logging: turning it on starts the once-a-second heartbeat immediately
            // (no relaunch); the same key can also be set with NOIRO_PROBE=1 at launch.
            choiceRow(String(localized: "Diagnostic logging"),
                      [("0", "Off"), ("1", "On")],
                      selection: Binding(get: { probeLogging ? "1" : "0" },
                                         set: { probeLogging = ($0 == "1"); if probeLogging { VXProbeHeartbeat.start() } }))
            Text("Logs detailed activity for troubleshooting.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            // Apple TV has no share sheet, so the diagnostic log is exported over the LAN: this stands up a
            // tiny local server and shows a QR the owner scans with their phone to download the log file.
            Button {
                diagExport = VXDiagExport.shared.start()
                settings.beginTaskPresentation()
                showDiagExport = true
            } label: { Text("Export diagnostic log") }
                .buttonStyle(ChipButtonStyle(selected: false))
        }
    }

    /// Full-screen QR export overlay: the phone scans the code, downloads noiro-diag.log over the LAN, and
    /// sends it on. Dismissing stops the local server so the log is not left served.
    @ViewBuilder private var diagExportSheet: some View {
        VStack(spacing: Theme.Space.lg) {
            Text("Export diagnostic log")
                .font(Theme.Typography.screenTitle).foregroundStyle(Theme.Palette.textPrimary)
            if let export = diagExport {
                export.qr
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 420, height: 420)
                    .background(Color.white)
                    .padding(Theme.Space.md)
                Text(export.url)
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text("Scan with your phone on the same Wi-Fi to download the log, then send it over.")
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Connect this device to Wi-Fi to export the diagnostic log.")
                    .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showDiagExport = false
                VXDiagExport.shared.stop()
                diagExport = nil
            } label: { Text("Done") }
                .buttonStyle(ChipButtonStyle(selected: true))
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.canvas.ignoresSafeArea())
    }

    private func choiceRow(_ label: String, _ options: [(id: String, label: String)],
                           selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(options, id: \.id) { opt in
                        Button { selection.wrappedValue = opt.id } label: { Text(opt.label) }
                            .buttonStyle(ChipButtonStyle(selected: selection.wrappedValue == opt.id))
                    }
                }
            }
        }
        // Each row is its own focus section so Down moves between stacked rows (e.g. Size ->
        // Color -> Background) without first leveling onto the chip beneath the focused one.
        .focusSection()
    }

    /// Numeric variant of `choiceRow` for a `Double`-backed setting (e.g. the max file-size cap).
    private func choiceRow(_ label: String, _ options: [(id: Double, label: String)],
                           selection: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(options, id: \.id) { opt in
                        Button { selection.wrappedValue = opt.id } label: { Text(opt.label) }
                            .buttonStyle(ChipButtonStyle(selected: selection.wrappedValue == opt.id))
                    }
                }
            }
        }
        .focusSection()
    }

    private func adjustSubScale(_ direction: Int) {
        let next = subSizeScale + Double(direction) * SubtitleStyle.sizeScaleStep
        let clamped = min(max(next, SubtitleStyle.sizeScaleRange.lowerBound), SubtitleStyle.sizeScaleRange.upperBound)
        subSizeScale = (clamped * 100).rounded() / 100
        ProfileStore.shared.capturePlayback()
    }

    private var leftTabTransparencyOptions: [(id: Double, label: String)] {
        (0...10).map { step in
            (id: Double(step) / 10, label: "\(step * 10)%")
        }
    }

    /// A label with minus / value / plus controls, for continuous settings (text and subtitle size).
    private func stepperRow(_ label: String, value: Double, range: ClosedRange<Double>,
                            onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(label).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.md) {
                Button(action: onMinus) { Image(systemName: "minus") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .disabled(value <= range.lowerBound + 0.001)
                    .opacity(value <= range.lowerBound + 0.001 ? 0.3 : 1)
                Text("\(Int((value * 100).rounded()))%")
                    .font(Theme.Typography.body.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(minWidth: 90)
                Button(action: onPlus) { Image(systemName: "plus") }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .disabled(value >= range.upperBound - 0.001)
                    .opacity(value >= range.upperBound - 0.001 ? 0.3 : 1)
            }
        }
        .focusSection()
    }

    // MARK: About

    private var backupSection: some View {
        section("Backup & Restore") {
            Text("A backup saves your profiles, theme, and player preferences so they travel with you and survive a future major update. On iPhone, iPad, and Mac you can save that to a file today.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("Noiro Sync can receive signed safe settings from Studio. A future explicit Backup action will encrypt an opaque vault on this Apple TV; Vortexo will never receive its recovery key.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.top, Theme.Space.xs)
            Text("Export Library remains available on iPhone, iPad, and Mac. Apple TV has no file picker, and local library data is not uploaded merely because this device is paired.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.top, Theme.Space.xs)
        }
    }

    private var aboutSection: some View {
        section(String(localized: "About")) {
            if let update = updates.available {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Update available: \(update.name)", systemImage: "arrow.down.circle.fill")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text("Sideload the new IPA from the GitHub releases page, your sign-in and settings carry over.")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.vertical, Theme.Space.xs)
            }
            infoRow(String(localized: "Version"), appVersion)
            infoRow(String(localized: "Player"), String(localized: "KSPlayer · AVPlayer · libmpv"))
            infoRow(String(localized: "Server"), String(localized: "Stremio streaming server (nodejs-mobile)"))
            Button {
                settings.beginTaskPresentation()
                launch.replayFromSettings()
            } label: {
                Label("Welcome & setup", systemImage: "wand.and.stars")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            NavigationLink { TVWhatsNewView() } label: {
                Label("What's New", systemImage: "sparkles")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
        }
        .task { updates.checkIfStale(maxAge: 30 * 60) }   // a Settings visit deserves a fresh answer
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    // MARK: Section chrome

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        let route = route(for: title)
        NavigationLink {
            SettingsSectionPage(route: route) { content() }
        } label: {
            NoiroSettingsCategoryCard(
                route: route,
                status: status(for: route),
                tone: statusTone(for: route)
            )
        }
        .buttonStyle(RowFocusStyle())
    }

    private func route(for title: String) -> NoiroSettingsRoute {
        switch title {
        case "Profiles": return .profiles
        case "Language": return .language
        case "Account": return .account
        case "Stremio mirror": return .stremioMirror
        case "Playback": return .playback
        case "Notifications": return .notifications
        case "Streams": return .streams
        case "Community": return .community
        case "Streaming Server": return .server
        case "Live TV": return .liveTV
        case "Appearance": return .appearance
        case "Audio & Subtitles": return .audioSubtitles
        case "Subtitle Style": return .subtitleStyle
        case "Advanced (mpv options)": return .advanced
        case "Backup & Restore": return .backup
        case "About": return .about
        default: return .advanced
        }
    }

    private func status(for route: NoiroSettingsRoute) -> String? {
        switch route {
        case .profiles:
            return profiles.active?.name ?? String(localized: "Main")
        case .language:
            return langSelection == "system" ? String(localized: "System") : langSelection.uppercased()
        case .account:
            if sync.isPaired && account.isSignedIn { return String(localized: "2 connected") }
            if sync.isPaired { return String(localized: "Sync connected") }
            if account.isSignedIn { return String(localized: "Stremio connected") }
            return String(localized: "Local")
        case .stremioMirror:
            let enabled = [mirrorAddons, mirrorLibrary, mirrorCW].filter { $0 }.count
            return enabled == 0 ? String(localized: "Independent") : "\(enabled) on"
        case .playback:
            return effectiveDirectLinksOnly ? String(localized: "Direct links") : String(localized: "Automatic")
        case .notifications:
            return notifyNewEpisodes ? String(localized: "On") : String(localized: "Off")
        case .streams:
            return "\(core.addons.filter(\.providesStreams).count) add-ons"
        case .community:
            return moatContribute ? String(localized: "On") : String(localized: "Private")
        case .server:
            return serverText
        case .liveTV:
            return hideLiveTab ? String(localized: "Hidden") : String(localized: "Visible")
        case .appearance:
            return theme.oled ? String(localized: "OLED") : String(localized: "Standard")
        case .audioSubtitles:
            return prefSubLang.uppercased()
        case .subtitleStyle:
            return String(localized: "Customizable")
        case .advanced:
            return probeLogging ? String(localized: "Diagnostics on") : String(localized: "Standard")
        case .backup:
            return String(localized: "Device local")
        case .about:
            return appVersion
        case .engine:
            return nil
        }
    }

    private func statusTone(for route: NoiroSettingsRoute) -> NoiroSettingsStatusTone {
        switch route {
        case .account:
            return (sync.isPaired || account.isSignedIn) ? .healthy : .neutral
        case .server:
            return serverOnline == true ? .healthy : (serverOnline == false ? .warning : .neutral)
        case .notifications, .community:
            return status(for: route) == String(localized: "On") ? .healthy : .neutral
        case .appearance, .language, .profiles, .streams:
            return .accent
        default:
            return .neutral
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Text(value).foregroundStyle(Theme.Palette.textSecondary)
        }
        .font(Theme.Typography.body)
    }
}

/// A pushed settings detail page (Vortexo parity): the section title as the screen title, then the
/// section's options in a scrolling column. Each settings section row drills into one of these.
private struct SettingsSectionPage<Content: View>: View {
    let route: NoiroSettingsRoute
    @EnvironmentObject private var settings: NoiroSettingsCoordinator
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content

    var body: some View {
        NoiroSettingsPanelPage {
            NoiroSettingsGroupCard {
                content()
            }
        }
        .onAppear {
            settings.registerExternalRoute(route) { dismiss() }
        }
        .onDisappear {
            settings.unregisterExternalRoute(route)
        }
    }
}

private struct TogglePill: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(isOn ? "On" : "Off")
                .font(Theme.Typography.eyebrow)
                .tracking(1)
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.Palette.accent.opacity(0.24) : Theme.Palette.surface3)
                    .frame(width: 64, height: 34)
                Circle()
                    .fill(isOn ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .frame(width: 24, height: 24)
                    .padding(.horizontal, 5)
            }
        }
        .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Palette.surface2, in: Capsule(style: .continuous))
    }
}

private struct UnavailableBadge: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(Theme.Typography.eyebrow)
            .tracking(1)
            .foregroundStyle(Theme.Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.Palette.surface2, in: Capsule(style: .continuous))
    }
}

struct ThemeAccentPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Accent").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.md) {
                    ForEach(ThemeManager.accents) { opt in
                        Button { selection = opt.id } label: {
                            AccentCircle(color: opt.base, selected: selection == opt.id)
                        }
                        .buttonStyle(CardFocusStyle())
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, Theme.Space.md)   // room for the focus halo on the swatches
            }
        }
    }
}

struct ThemeBackgroundPicker: View {
    @Binding var oled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Background").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: Theme.Space.sm) {
                Button("Warm") { oled = false }
                    .buttonStyle(ChipButtonStyle(selected: !oled))
                Button("OLED Black") { oled = true }
                    .buttonStyle(ChipButtonStyle(selected: oled))
            }
        }
    }
}

private struct AccentCircle: View {
    let color: Color
    let selected: Bool
    @Environment(\.isFocused) private var focused

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 58, height: 58)
            .overlay(Circle().strokeBorder(ringColor, lineWidth: ringWidth))
    }

    private var ringColor: Color {
        focused ? Theme.Palette.accentBright : Theme.Palette.textPrimary
    }

    private var ringWidth: CGFloat {
        focused || selected ? 5 : 0
    }
}
