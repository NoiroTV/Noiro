import SwiftUI
import UIKit

/// A request to play something full-screen.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var meta: PlaybackMeta? = nil
    var episodes: [CoreVideo] = []
    /// Quality signature of the stream being played, so auto-next can prefer the
    /// same release family for the following episode.
    var sourceHint: String? = nil
    /// True when the stream rides the embedded torrent engine, which needs warm-up
    /// patience the player gives it.
    var torrent: Bool = false
    /// The add-on's release-group tag for the playing stream, so auto-next can lock
    /// the next episode to the same release.
    var bingeGroup: String? = nil
    /// HTTP request headers the stream's add-on requires (behaviorHints.proxyHeaders).
    var headers: [String: String]? = nil
    /// Force the libmpv player even when the router would pick AVPlayer (the last-resort escape hatch).
    /// TVPlayerView now demotes a failed AVPlayer item to libmpv IN PLACE (`avEngineFailed`), so this is no
    /// longer needed for the common load failure; it remains for any path that wants to bypass AVPlayer
    /// routing entirely and mount libmpv directly.
    var forceMPV: Bool = false
    /// FIX I: this request plays a TRAILER clip (the {server}/yt/{id} route), not a content stream. When a
    /// trailer fails to load, the player must NOT fall back to the engine's content streams (that would
    /// substitute the actual/random movie for the dead trailer); it shows the error overlay and stops.
    var isTrailer: Bool = false
    /// When this request plays a NATIVELY-resolved debrid link, its provenance so the play-record can store
    /// enough to reresolve a fresh link on a later Continue-Watching resume. nil for torrent/direct/trailer.
    var debridRef: DebridPlaybackRef? = nil
    /// yt-direct adaptive pair (trailers / pasted YouTube links): the separate AUDIO stream mpv mounts
    /// alongside the video-only `url` (`--audio-files`). Forces the libmpv engine in TVPlayerView.
    var audioSidecarURL: URL? = nil
    /// True when the user explicitly chose this exact source (a tapped source-list row / quality pick),
    /// false for an auto-pick (Watch Now / a Continue-Watching resume). TVPlayerView honors an explicit
    /// pick on a start-timeout (retries in place) instead of silently hopping to a lower-quality source.
    var wasExplicitPick: Bool = false
    /// True when this play is a Continue-Watching RESUME (directResume). A resume plays its exact stored source
    /// FIRST (like an explicit pick, so a slow warming link retries in place rather than hopping), but on a HARD
    /// load failure it MUST hop to a fresh source instead of dead-ending: a stored debrid link expires, and the
    /// resume's job is to get you watching. Distinct from wasExplicitPick, where a manual source-row tap dead-ends.
    var wasResume: Bool = false
}

/// Holds the active playback request. Set it to present the player; clear it to dismiss.
final class PlayerPresenter: ObservableObject {
    /// True for the short handoff from the full-screen player back to the still-mounted shell. The rail reads
    /// this in the same update that clears `request`, so it is never eligible as tvOS's first return target.
    @Published private(set) var isRestoringShellFocus = false
    private var shellFocusRestoreWork: DispatchWorkItem?

    @Published var request: PlaybackRequest? {
        didSet {
            if request?.torrent == true && PlaybackSettings.torrentsDisabled {
                request = nil
            }
        }
    }

    func closePlayback() {
        guard request != nil else { return }
        shellFocusRestoreWork?.cancel()
        isRestoringShellFocus = true
        request = nil

        let work = DispatchWorkItem { [weak self] in self?.isRestoringShellFocus = false }
        shellFocusRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
}

/// App root, with the navigation shell mounted once so its current page survives modal playback.
///  - The profile picker presents as a REAL modal (fullScreenCover). UIKit moves focus into actual
///    presentations natively on a Siri remote; the hand-rolled ZStack overlay it replaces could
///    never receive focus on device. (The editor and login covers prove modal focus works here.)
///  - The player presents OVER the live but hidden + disabled shell, so closing it returns to the
///    exact page playback started from; the player's catcher window owns the remote (TVPlayerView).
struct RootView: View {
    @EnvironmentObject private var presenter: PlayerPresenter
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var launch: NoiroLaunchCoordinator

    var body: some View {
        ZStack {
            // Brand canvas behind everything, so the moment between the splash fading
            // and the profile picker animating in shows the app's own background, never
            // a flash of the main profile's Home underneath.
            Theme.Palette.canvas.ignoresSafeArea()
            RootTabView()
                .opacity(shellVisible ? 1 : 0)
                .disabled(!shellVisible)
            if let req = presenter.request {
                // #76: AVPlayer is now FIRST-CLASS under the full TVPlayerView chrome. Every request goes to
                // TVPlayerView, which picks the engine per stream in `playerSurface` (AVPlayer for HLS / Dolby
                // Vision in an AVPlayer-playable container, libmpv for torrents / MKV / everything else) and
                // demotes AVPlayer to libmpv in place on a load failure. The chrome (control bar, scrubber,
                // panels, failover) renders identically over either engine, and remote input always stays on
                // the UIKit RemoteCatcher, so AVKit never fights the Siri-remote focus engine. `forceMPV` (the
                // last-resort escape hatch) just means TVPlayerView mounts libmpv directly.
                TVPlayerView(url: req.url, title: req.title, meta: req.meta, episodes: req.episodes,
                             sourceHint: req.sourceHint, torrent: req.torrent, bingeGroup: req.bingeGroup,
                             headers: req.headers, forceMPV: req.forceMPV, isTrailer: req.isTrailer,
                             audioSidecarURL: req.audioSidecarURL, debridRef: req.debridRef,
                             startedFromExplicitPick: req.wasExplicitPick, startedFromResume: req.wasResume,
                             onClose: { presenter.closePlayback() })
                    .id(req.id)   // clean player teardown per request
            }
        }
        .fullScreenCover(isPresented: pickerPresented) { ProfilePickerView() }
    }

    /// Cold start with a real choice, or Settings' "Switch Profile". Dismissing with Menu counts
    /// as picking the current profile, so the binding's setter just marks the launch as picked.
    /// Home stays hidden until a profile is settled: while the picker is owed (more
    /// than one profile, none chosen this launch) the shell is invisible, so nothing
    /// of the main profile leaks out before the picker arrives.
    private var shellVisible: Bool {
        presenter.request == nil && !profiles.needsPicker
    }

    private var pickerPresented: Binding<Bool> {
        Binding(
            get: { launch.isContentInteractive && profiles.needsPicker && presenter.request == nil },
            set: { presented in if !presented { profiles.pickedThisLaunch = true } }
        )
    }
}

/// Shared persistence for the custom left navigation rail's appearance.
enum LeftTabRailSettings {
    static let transparencyKey = "noiro.leftTab.transparency"
    static let defaultTransparency = 0.15
    static let transparencyRange = 0.0...1.0
}

/// The app shell: Home · Discover · Library · Add-ons · Search · Settings.
///
/// Noiro uses one consistent left navigation rail. Settings opens above the active destination rather
/// than becoming a destination itself, so closing it restores the exact screen beneath it.
struct RootTabView: View {
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var launch: NoiroLaunchCoordinator
    @EnvironmentObject private var presenter: PlayerPresenter
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var selection = 0
    /// Settings presents above the active tab so Home/Discover/etc. remain alive and visible behind it.
    @StateObject private var settings = NoiroSettingsCoordinator()
    @State private var updateMonitoringStarted = false
    // Per-tab identity token. Each tab owns its own NavigationStack whose pushed pages persist
    // while the tab stays alive (tvOS keeps tabs mounted). Bumping the token of the tab you LEAVE
    // changes that tab's view identity, so the next time you open it SwiftUI rebuilds it fresh at
    // its root instead of re-showing the detail page you had pushed (the "Search still shows the
    // series I opened" bug). Cheap because the data lives in CoreBridge, not in the view.
    @State private var resetTokens = [Int](repeating: 0, count: 7)
    /// Hide the Live TV tab for users who do not use it (Settings toggle).
    @AppStorage("noiro.hideLiveTab") private var hideLiveTab = false
    @FocusState private var leftRailFocus: Int?
    /// The shell stays mounted (but disabled) behind full-screen playback. When that disabled tree becomes
    /// active again, tvOS can otherwise choose the leading rail as its first eligible focus region and open
    /// it even though playback was launched from the content. Briefly remove the rail from focus search while
    /// the underlying page restores its prior responder.
    @State private var suppressLeftRailFocus = false

    /// The tvOS scroll-to-top key for a tab tag, matching the `TabScrollKeys` the screens observe.
    /// Navigation selection uses integer tags; only Home / Discover / Library carry a scrollable
    /// hero screen wired for scroll-to-top. Search / Add-ons / Settings are lists or their own
    /// containers, and Live (tag 6) is an EPG grid, so they are intentionally omitted here (returning
    /// nil means a re-select is a plain no-op, not a bump nobody observes).
    private func scrollKey(for tag: Int) -> String? {
        switch tag {
        case 0: return TabScrollKeys.home
        case 1: return TabScrollKeys.discover
        case 2: return TabScrollKeys.library
        default: return nil
        }
    }

    /// Human-readable name for a tab tag, used for VXProbe route/nav probes. Matches the tab tags
    /// (Live 6, Search 4, Add-ons 3, Settings 5) so a diagnostic log names the screen the user is on.
    static func tabName(_ tag: Int) -> String {
        switch tag {
        case 0: return "Home"
        case 1: return "Discover"
        case 2: return "Library"
        case 3: return "Add-ons"
        case 4: return "Search"
        case 5: return "Settings"
        case 6: return "Live"
        default: return "tab\(tag)"
        }
    }

    /// Selection binding that turns a re-select of the ALREADY-active tab into a scroll-to-top signal.
    /// The left rail calls this setter when the user activates an item; when the new value equals the
    /// current selection (re-tapping the active tab) we bump that tab's token instead of a no-op set, so
    /// the mounted screen scrolls to its top. A genuine tab switch sets `selection` as before.
    private var selectionBinding: Binding<Int> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == 5 {
                    settings.open()
                    return
                }
                if newValue == selection, let key = scrollKey(for: newValue) {
                    TabScrollToTop.shared.bump(key)
                } else {
                    selection = newValue
                }
            }
        )
    }

    /// The left rail deliberately mounts only the active destination while the selection/reset
    /// bookkeeping provides a fresh root whenever the user returns to a destination.
    @ViewBuilder private var selectedContent: some View {
        switch selection {
        case 0:
            HomeView().id(resetTokens[0])
        case 1:
            DiscoverView().id(resetTokens[1])
        case 2:
            LibraryView().id(resetTokens[2])
        case 3:
            AddonsView().id(resetTokens[3])
        case 4:
            NavigationStack { SearchView() }.id(resetTokens[4])
        case 5:
            // The selection binding intercepts Settings before this can become active. Keep a safe
            // fallback for restored/stale selection state without mounting a second Settings tree.
            HomeView().id(resetTokens[0])
        case 6 where !hideLiveTab:
            LiveView().id(resetTokens[6])
        default:
            HomeView().id(resetTokens[0])
        }
    }

    private var leftTabShell: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                selectedContent
                    .frame(width: proxy.size.width, height: proxy.size.height)

                LeftTabRail(
                    selection: selectionBinding,
                    focusedTag: $leftRailFocus,
                    focusSuppressed: suppressLeftRailFocus || presenter.isRestoringShellFocus,
                    hideLiveTab: hideLiveTab,
                    settingsPresented: settings.isPresented,
                    profileName: profiles.active?.name ?? String(localized: "Account"),
                    profileAvatar: profiles.active?.avatar ?? "?",
                    openProfiles: {
                        settings.close()
                        DispatchQueue.main.async { profiles.pickedThisLaunch = false }
                    }
                )
                .zIndex(50)
            }
        }
    }

    var body: some View {
        leftTabShell
        .tint(theme.accent)
        .noiroSettingsOverlay(coordinator: settings) {
            SettingsView()
        }
        // Back/Menu floor, depth-aware. SwiftUI routes the exit command to the NEAREST .onExitCommand in the
        // focused view's ancestry BEFORE UIKit's default NavigationStack pop, so this shell-level handler
        // fires from ANY push depth on a non-Home tab (55ceff8 assumed pushed pages kept a deeper Menu
        // responder; none exists, and the system pop never outranks a SwiftUI handler). When the active
        // tab's stack has a page pushed, pop exactly one level (the same UINavigationController pop the
        // system default performs on the Home tab, where this handler is nil); only at the tab's ROOT does
        // Menu route to Home (the Beta-10 floor; the .onChange below then resets the tab we left). Home
        // keeps nil so Menu at the Home root still suspends to tvOS.
        .onExitCommand(perform: selection == 0 ? nil : {
            if let nav = focusedNavigationController(), nav.viewControllers.count > 1 {
                nav.popViewController(animated: true)
            } else {
                selection = 0
            }
        })
        // Automatic update popup on the shell (never over the player, which replaces this view). Appears once
        // per launch when a newer build exists, and again when the hourly re-check finds a still-newer one.
        .sheet(item: updatePromptBinding) { release in
            UpdatePromptView(release: release) { updates.dismissPrompt() }
        }
        .onAppear {
            startUpdateMonitoringIfReady()
            let name = Self.tabName(selection)
            VXProbeState.shared.setRoute(name)
            VXProbe.event("nav", "tab \(name)")
        }
        .onChange(of: launch.isContentInteractive) { _, interactive in
            if interactive {
                settings.endTaskPresentation()
                startUpdateMonitoringIfReady()
            }
        }
        .onChange(of: presenter.request?.id) { oldRequestID, newRequestID in
            if oldRequestID != nil, newRequestID == nil {
                restoreContentFocusAfterPlayback()
            }
        }
        // Reset the tab being LEFT to its root, so returning to it lands on the root page.
        .onChange(of: selection) { old, new in
            if old >= 0, old < resetTokens.count { resetTokens[old] += 1 }
            let name = Self.tabName(new)
            VXProbeState.shared.setRoute(name)
            VXProbe.event("nav", "tab \(name)")
        }
        // If Live is hidden while it was the selected tab (e.g. synced from another device), fall back to Home
        // so the TabView never points at a tag that no longer exists.
        .onChange(of: hideLiveTab) { _, hidden in
            if hidden, selection == 6 { selection = 0 }
        }
        // The active profile owns the theme: mirror Settings changes into it so they survive a switch.
        .onChange(of: theme.accentID) { ProfileStore.shared.captureTheme() }
        .onChange(of: theme.oled) { ProfileStore.shared.captureTheme() }
        .onChange(of: theme.textScale) { ProfileStore.shared.captureTheme() }
    }

    private var updatePromptBinding: Binding<UpdateChecker.Release?> {
        Binding(
            get: { launch.isContentInteractive && !settings.isPresented ? updates.prompt : nil },
            set: { updates.prompt = $0 }
        )
    }

    private func startUpdateMonitoringIfReady() {
        guard launch.isContentInteractive, !updateMonitoringStarted else { return }
        updateMonitoringStarted = true
        updates.startMonitoring()
    }

    /// Return focus to the still-mounted page after the player closes without allowing the leading rail to
    /// become tvOS's temporary default. This mirrors the rail's explicit Right-arrow handoff: disable the rail
    /// for one focus update, clear its focus binding, then let UIKit restore the page's previous focused item.
    private func restoreContentFocusAfterPlayback() {
        suppressLeftRailFocus = true
        leftRailFocus = nil

        DispatchQueue.main.async {
            DispatchQueue.main.async {
                let windows = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                let window = windows.first(where: \.isKeyWindow) ?? windows.first
                window?.rootViewController?.setNeedsFocusUpdate()
                window?.rootViewController?.updateFocusIfNeeded()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    suppressLeftRailFocus = false
                }
            }
        }
    }

    /// The UIKit navigation controller backing the ACTIVE tab's `NavigationStack`, resolved from the
    /// focused item's responder chain (SwiftUI's NavigationStack is UINavigationController-backed on
    /// tvOS). Focus always lives inside the visible tab, so a dormant tab's stack can never resolve.
    /// Returns nil when the focused item is not inside a navigation controller (tab bar focused,
    /// mid-transition, or a future OS changing internals); the caller treats nil as "at root", so the
    /// worst case is the old go-Home behavior, never a crash or a dead Menu press.
    private func focusedNavigationController() -> UINavigationController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return nil }
        // The focused item can be a non-view SwiftUI focus proxy: climb the focus-environment chain to
        // the first real UIView / UIViewController, then walk the responder chain to the enclosing stack.
        var environment: (any UIFocusEnvironment)? = UIFocusSystem.focusSystem(for: window)?.focusedItem
        var responder: UIResponder?
        while let env = environment {
            if let view = env as? UIView { responder = view; break }
            if let vc = env as? UIViewController { responder = vc; break }
            environment = env.parentFocusEnvironment
        }
        while let r = responder {
            if let nav = r as? UINavigationController { return nav }
            if let vc = r as? UIViewController, let nav = vc.navigationController { return nav }
            responder = r.next
        }
        return nil
    }

}

/// Noiro's left navigation. It rests as a slim icon strip, then opens its labels
/// over a translucent black fade while the rail owns focus. There are no large focus plates, and a
/// short theme-colour marker identifies the active destination. Content behind it never reflows.
private struct LeftTabRail: View {
    @EnvironmentObject private var theme: ThemeManager
    @AppStorage(LeftTabRailSettings.transparencyKey) private var transparency = LeftTabRailSettings.defaultTransparency
    @State private var handingFocusToContent = false
    @Binding var selection: Int
    var focusedTag: FocusState<Int?>.Binding
    let focusSuppressed: Bool
    let hideLiveTab: Bool
    let settingsPresented: Bool
    let profileName: String
    let profileAvatar: String
    let openProfiles: () -> Void

    private let accountTag = -1
    private var isOpen: Bool { focusedTag.wrappedValue != nil }
    private var backgroundStrength: Double {
        1 - min(max(transparency, LeftTabRailSettings.transparencyRange.lowerBound),
                LeftTabRailSettings.transparencyRange.upperBound)
    }
    private var trailingBackgroundStrength: Double {
        // 0% transparency remains uniformly black. As transparency increases, the outside edge
        // fades sooner so the compact rail visually merges into the hero artwork like Netflix.
        backgroundStrength * max(0, 1 - transparency * 3.4)
    }

    private var items: [(tag: Int, title: String, icon: String)] {
        var value: [(Int, String, String)] = [
            (4, String(localized: "Search"), "magnifyingglass"),
            (0, String(localized: "Home"), "house.fill"),
            (1, String(localized: "Discover"), "safari.fill")
        ]
        if !hideLiveTab {
            value.append((6, String(localized: "Live"), "dot.radiowaves.left.and.right"))
        }
        value.append(contentsOf: [
            (2, String(localized: "Library"), "books.vertical.fill"),
            (3, String(localized: "Add-ons"), "puzzlepiece.extension.fill"),
            (5, String(localized: "Settings"), "gearshape.fill")
        ])
        return value
    }

    private var focusOrder: [Int] {
        [accountTag] + items.map(\.tag)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            railButton(tag: accountTag, title: profileName, icon: nil, avatar: profileAvatar) {
                openProfiles()
            }

            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(items, id: \.tag) { item in
                    railButton(tag: item.tag, title: item.title, icon: item.icon) {
                        selection = item.tag
                    }
                }
            }

            Spacer(minLength: 20)
        }
        .padding(.vertical, 34)
        .padding(.horizontal, isOpen ? 12 : 5)
        .frame(width: isOpen ? 210 : 78, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(backgroundStrength), location: 0),
                    .init(color: .black.opacity(backgroundStrength), location: isOpen ? 0.68 : 0.74),
                    .init(color: .black.opacity(trailingBackgroundStrength), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .disabled(handingFocusToContent || focusSuppressed)
        .focusSection()
        .animation(.easeOut(duration: 0.18), value: isOpen)
        .animation(.easeOut(duration: 0.18), value: transparency)
        .ignoresSafeArea()
    }

    private func railButton(
        tag: Int,
        title: String,
        icon: String?,
        avatar: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let focused = focusedTag.wrappedValue == tag
        let selected = tag >= 0 && (selection == tag || (tag == 5 && settingsPresented))

        return Button(action: action) {
            HStack(spacing: 10) {
                VStack(spacing: 3) {
                    ZStack {
                        if let avatar {
                            Circle()
                                .fill(Color.white.opacity(focused ? 0.18 : 0.09))
                                .overlay {
                                    Circle().strokeBorder(Color.white.opacity(focused ? 0.72 : 0.20), lineWidth: 1.5)
                                }
                            Text(avatar).font(.system(size: 21))
                        } else if let icon {
                            Image(systemName: icon)
                                .font(.system(size: 23, weight: focused || selected ? .semibold : .regular))
                                .foregroundStyle(focused || selected ? Color.white : Theme.Palette.textSecondary)
                        }
                    }
                    .frame(width: 44, height: 36)

                    Capsule()
                        .fill(selected ? theme.accent : Color.clear)
                        .frame(width: 22, height: 3)
                }
                .frame(width: 56, height: 49)

                if isOpen {
                    if avatar != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.white)
                            Text("Switch Profiles")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    } else {
                        Text(title)
                            .font(.system(size: 20, weight: selected ? .bold : .semibold))
                            .foregroundStyle(focused || selected ? Color.white : Theme.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: isOpen ? 186 : 56, height: 49, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(LeftRailButtonStyle())
        .focusEffectDisabled()
        .focused(focusedTag, equals: tag)
        .onMoveCommand { direction in
            moveFocus(from: tag, direction: direction)
        }
        .scaleEffect(focused ? 1.06 : 1, anchor: .center)
        .animation(.easeOut(duration: 0.12), value: focused)
        .accessibilityLabel(title)
    }

    /// Up and Down are deterministic inside the overlay instead of being left to the spatial
    /// focus engine, which can otherwise see the Settings rows behind the rail through its gaps.
    /// At either end we hold focus on the end item rather than letting it escape vertically.
    private func moveFocus(from tag: Int, direction: MoveCommandDirection) {
        guard let index = focusOrder.firstIndex(of: tag) else { return }
        switch direction {
        case .up:
            focusedTag.wrappedValue = focusOrder[max(0, index - 1)]
        case .down:
            focusedTag.wrappedValue = focusOrder[min(focusOrder.count - 1, index + 1)]
        case .right:
            handFocusToContent()
        default:
            break
        }
    }

    /// A plain `focusedTag = nil` only succeeds when the page happens to have a control on the same
    /// horizontal line as the current rail item. Remove the entire rail from the focus search for one
    /// update and ask UIKit to resolve focus again; the active page is then the only eligible region,
    /// so every rail row exits consistently regardless of its vertical position.
    private func handFocusToContent() {
        guard !handingFocusToContent else { return }
        handingFocusToContent = true
        focusedTag.wrappedValue = nil

        DispatchQueue.main.async {
            DispatchQueue.main.async {
                let windows = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                let window = windows.first(where: \.isKeyWindow) ?? windows.first
                window?.rootViewController?.setNeedsFocusUpdate()
                window?.rootViewController?.updateFocusIfNeeded()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    handingFocusToContent = false
                }
            }
        }
    }
}

/// A label-only button style. tvOS 26's built-in plain style still paints a large glass focus plate
/// around the full button; this keeps focus presentation on the compact icon itself.
private struct LeftRailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
