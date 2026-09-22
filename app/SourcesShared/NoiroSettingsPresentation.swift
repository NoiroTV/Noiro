import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shared presentation state for the premium Settings drawer. The app shells own one coordinator
/// each so opening Settings never changes (or rebuilds) the content tab underneath it.
@MainActor
final class NoiroSettingsCoordinator: ObservableObject {
    @Published private(set) var isPresented = false
    @Published var path: [NoiroSettingsRoute] = []
    @Published private(set) var isPresentingTask = false
    @Published private(set) var externallyPresentedRoute: NoiroSettingsRoute?
    private var externalBackAction: (() -> Void)?

    var canGoBack: Bool { externallyPresentedRoute != nil || !path.isEmpty }
    var currentRoute: NoiroSettingsRoute? { externallyPresentedRoute ?? path.last }

    func open() {
        isPresentingTask = false
        isPresented = true
    }

    func show(_ route: NoiroSettingsRoute) {
        if !isPresented { open() }
        path.append(route)
    }

    func goBack() {
        if let externalBackAction {
            self.externalBackAction = nil
            externallyPresentedRoute = nil
            externalBackAction()
            return
        }
        guard !path.isEmpty else {
            close()
            return
        }
        path.removeLast()
    }

    func close() {
        isPresented = false
        isPresentingTask = false
        externallyPresentedRoute = nil
        externalBackAction = nil
        path.removeAll()
    }

    /// Task-focused flows (profile picker, first-run replay, authentication) temporarily sit above
    /// Settings. Keeping the route while they are active lets their dismissal return to the exact page.
    func beginTaskPresentation() {
        isPresentingTask = true
    }

    func endTaskPresentation() {
        isPresentingTask = false
    }

    /// Some existing tvOS destinations are destination-based NavigationLinks. Registering their
    /// dismiss action keeps the fixed panel header's Back button authoritative without rewriting
    /// the underlying controls or their navigation semantics.
    func registerExternalRoute(_ route: NoiroSettingsRoute, back: @escaping () -> Void) {
        externallyPresentedRoute = route
        externalBackAction = back
    }

    func unregisterExternalRoute(_ route: NoiroSettingsRoute) {
        guard externallyPresentedRoute == route else { return }
        externallyPresentedRoute = nil
        externalBackAction = nil
    }
}

/// Category routes shared by the touch/Mac and tvOS Settings implementations. Unsupported categories
/// are simply omitted from that platform's dashboard; persistence and setting ownership stay unchanged.
enum NoiroSettingsRoute: String, CaseIterable, Hashable, Identifiable {
    case profiles
    case language
    case account
    case stremioMirror
    case playback
    case notifications
    case streams
    case community
    case server
    case liveTV
    case appearance
    case audioSubtitles
    case subtitleStyle
    case advanced
    case backup
    case about
    case engine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profiles: return String(localized: "Profiles")
        case .language: return String(localized: "Language")
        case .account: return String(localized: "Account")
        case .stremioMirror: return String(localized: "Stremio mirror")
        case .playback: return String(localized: "Playback")
        case .notifications: return String(localized: "Notifications")
        case .streams: return String(localized: "Streams")
        case .community: return String(localized: "Community")
        case .server: return String(localized: "Streaming Server")
        case .liveTV: return String(localized: "Live TV")
        case .appearance: return String(localized: "Appearance")
        case .audioSubtitles: return String(localized: "Audio & Subtitles")
        case .subtitleStyle: return String(localized: "Subtitle Style")
        case .advanced: return String(localized: "Advanced")
        case .backup: return String(localized: "Backup & Restore")
        case .about: return String(localized: "About")
        case .engine: return String(localized: "Engine")
        }
    }

    var summary: String {
        switch self {
        case .profiles: return String(localized: "Choose who is watching and manage profile privacy.")
        case .language: return String(localized: "Choose the language Noiro uses across the app.")
        case .account: return String(localized: "Connect Noiro Sync, Stremio, and artwork services.")
        case .stremioMirror: return String(localized: "Control how Noiro follows your Stremio data.")
        case .playback: return String(localized: "Tune playback engines, caching, skipping, and output.")
        case .notifications: return String(localized: "Choose when Noiro alerts you about new episodes.")
        case .streams: return String(localized: "Rank sources, manage debrid, and filter stream results.")
        case .community: return String(localized: "Control optional community-powered media features.")
        case .server: return String(localized: "Review and configure the local streaming service.")
        case .liveTV: return String(localized: "Configure tuners, channels, and the Live TV experience.")
        case .appearance: return String(localized: "Personalize Noiro's color, layout, artwork, and scale.")
        case .audioSubtitles: return String(localized: "Set preferred tracks, translation, and language behavior.")
        case .subtitleStyle: return String(localized: "Refine subtitle type, color, background, and position.")
        case .advanced: return String(localized: "Manage expert playback and diagnostic options.")
        case .backup: return String(localized: "Move settings and library data safely between devices.")
        case .about: return String(localized: "Version, updates, release notes, and welcome setup.")
        case .engine: return String(localized: "Inspect the native media engine and local service state.")
        }
    }

    var icon: String {
        switch self {
        case .profiles: return "person.crop.circle.badge.plus"
        case .language: return "globe"
        case .account: return "person.crop.circle.fill"
        case .stremioMirror: return "arrow.triangle.2.circlepath"
        case .playback: return "play.circle.fill"
        case .notifications: return "bell.badge.fill"
        case .streams: return "bolt.horizontal.circle.fill"
        case .community: return "person.2.fill"
        case .server: return "server.rack"
        case .liveTV: return "dot.radiowaves.left.and.right"
        case .appearance: return "paintpalette.fill"
        case .audioSubtitles: return "captions.bubble.fill"
        case .subtitleStyle: return "textformat.size"
        case .advanced: return "slider.horizontal.3"
        case .backup: return "externaldrive.fill"
        case .about: return "info.circle.fill"
        case .engine: return "cpu"
        }
    }
}

enum NoiroSettingsSurface {
    case standalone
    case panel
}

private struct NoiroSettingsSurfaceKey: EnvironmentKey {
    static let defaultValue: NoiroSettingsSurface = .standalone
}

extension EnvironmentValues {
    var noiroSettingsSurface: NoiroSettingsSurface {
        get { self[NoiroSettingsSurfaceKey.self] }
        set { self[NoiroSettingsSurfaceKey.self] = newValue }
    }
}

/// Nested settings screens are also used outside the overlay in a few legacy routes. These helpers
/// let them keep their original full-screen presentation there while becoming visually contained when
/// the same view is pushed inside the premium panel.
struct NoiroSettingsPageTitle: View {
    @Environment(\.noiroSettingsSurface) private var surface
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    @ViewBuilder
    var body: some View {
        if surface == .panel {
            Text(title)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(title).screenTitleStyle()
        }
    }
}

struct NoiroSettingsPageBackground: View {
    @Environment(\.noiroSettingsSurface) private var surface

    var body: some View {
        Group {
            if surface == .standalone {
                Theme.Palette.canvas.ignoresSafeArea()
            } else {
                Color.clear
            }
        }
        .accessibilityHidden(true)
    }
}

private struct NoiroSettingsPageBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background { NoiroSettingsPageBackground() }
    }
}

extension View {
    func noiroSettingsPageBackground() -> some View {
        modifier(NoiroSettingsPageBackgroundModifier())
    }
}

enum NoiroSettingsStatusTone {
    case neutral
    case accent
    case healthy
    case warning

    var color: Color {
        switch self {
        case .neutral: return Theme.Palette.textSecondary
        case .accent: return Theme.Palette.accent
        case .healthy: return Theme.Palette.ok
        case .warning: return Theme.Palette.warn
        }
    }
}

/// Onboarding-style category card used by every platform's Settings dashboard.
struct NoiroSettingsCategoryCard: View {
    let route: NoiroSettingsRoute
    var status: String?
    var tone: NoiroSettingsStatusTone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Image(systemName: route.icon)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 34, alignment: .leading)
                Spacer(minLength: Theme.Space.xs)
                if let status, !status.isEmpty {
                    Text(status)
                        .font(Theme.Typography.eyebrow)
                        .foregroundStyle(tone.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(tone.color.opacity(0.12), in: Capsule())
                }
            }

            Text(route.title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(route.summary)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Label("Open", systemImage: "arrow.right")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.accent)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, minHeight: cardMinimumHeight, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(route.title) settings")
    }

    private var cardMinimumHeight: CGFloat {
        #if os(tvOS)
        return 220
        #else
        return 178
        #endif
    }
}

/// A custom settings group that replaces the system Form/Section chrome while leaving the existing
/// controls and AppStorage bindings untouched.
struct NoiroSettingsGroupCard<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            VStack(alignment: .leading, spacing: Theme.Space.md) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.md)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Consistent scrolling page for category and nested settings content. The panel header owns the title
/// and Back/Close controls, so pages only provide their controls and optional explanatory copy.
struct NoiroSettingsPanelPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                content()
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .background(Color.clear)
    }
}

/// The drawer's subtle version of the onboarding light field. It intentionally reuses the existing
/// code-built backdrop and overlays the current theme canvas so controls retain strong contrast.
private struct NoiroSettingsPanelBackdrop: View {
    var body: some View {
        ZStack {
            NoiroPrismaticBackdrop()
            Theme.Palette.canvas.opacity(0.76)
            LinearGradient(
                colors: [Color.white.opacity(0.035), .clear, Theme.Palette.accent.opacity(0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .accessibilityHidden(true)
    }
}

/// Shared panel frame and header. The child supplies the platform's settings dashboard/navigation stack.
struct NoiroSettingsPanelChrome<Content: View>: View {
    @ObservedObject var coordinator: NoiroSettingsCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            NoiroSettingsPanelBackdrop()

            VStack(spacing: 0) {
                header
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                embeddedContent
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.62), radius: 42, x: -18, y: 12)
        .shadow(color: Theme.Palette.accent.opacity(0.13), radius: 34, x: -10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
        .accessibilityAction(.escape) {
            if coordinator.canGoBack { coordinator.goBack() } else { coordinator.close() }
        }
        #if os(tvOS) || os(macOS)
        .onExitCommand {
            if coordinator.canGoBack {
                coordinator.goBack()
            } else {
                coordinator.close()
            }
        }
        #endif
        #if os(macOS)
        .overlay {
            NoiroSettingsKeyboardMonitor {
                if coordinator.canGoBack { coordinator.goBack() } else { coordinator.close() }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        #endif
    }

    @ViewBuilder
    private var embeddedContent: some View {
        #if os(iOS)
        content()
            .environment(\.noiroSettingsSurface, .panel)
            .toolbar(.hidden, for: .navigationBar)
        #elseif os(tvOS)
        content()
            .environment(\.noiroSettingsSurface, .panel)
            .focusSection()
        #else
        content()
            .environment(\.noiroSettingsSurface, .panel)
        #endif
    }

    private var header: some View {
        Group {
            if usesCompactHeader {
                compactHeader
            } else {
                regularHeader
            }
        }
        .padding(.horizontal, usesCompactHeader ? Theme.Space.md : Theme.Space.screenInset)
        .padding(.vertical, Theme.Space.md)
        .animation(reduceMotion ? nil : Theme.Motion.state, value: coordinator.path)
    }

    private var regularHeader: some View {
        HStack(spacing: Theme.Space.md) {
            if coordinator.canGoBack {
                Button { coordinator.goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            } else {
                NoiroWordmark(fontSize: headerWordmarkSize)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.currentRoute?.title ?? String(localized: "Settings"))
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if coordinator.path.isEmpty {
                    Text("Make Noiro yours")
                        .font(Theme.Typography.eyebrow)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }

            Spacer(minLength: Theme.Space.sm)

            Button { coordinator.close() } label: {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            .accessibilityHint("Closes Settings and returns to the current screen")
        }
    }

    private var compactHeader: some View {
        HStack(spacing: Theme.Space.sm) {
            if coordinator.canGoBack {
                Button { coordinator.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                .accessibilityLabel("Back")
            } else {
                NoiroWordmark(fontSize: 15)
            }

            Text(coordinator.currentRoute?.title ?? String(localized: "Settings"))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: Theme.Space.xs)

            Button { coordinator.close() } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(ChipButtonStyle(selected: false))
            .accessibilityLabel("Close")
            .accessibilityHint("Closes Settings and returns to the current screen")
        }
    }

    private var usesCompactHeader: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    private var headerWordmarkSize: CGFloat {
        #if os(tvOS)
        return 27
        #else
        return 20
        #endif
    }
}

#if os(macOS)
/// SwiftUI's hidden shortcut buttons do not consistently receive Escape when focus is inside a
/// NavigationStack. A panel-scoped event monitor makes Escape and Command-[ deterministic, and is
/// removed with the panel so it never changes keyboard handling elsewhere in the app.
private struct NoiroSettingsKeyboardMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.start()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var action: () -> Void
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let isEscape = event.keyCode == 53
                let isCommandBack = event.modifierFlags.contains(.command)
                    && event.charactersIgnoringModifiers == "["
                guard isEscape || isCommandBack else { return event }
                self?.action()
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stop()
        }
    }
}
#endif

private struct NoiroSettingsOverlayModifier<PanelContent: View>: ViewModifier {
    @ObservedObject var coordinator: NoiroSettingsCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let panelContent: () -> PanelContent

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            compactPresentation(content)
        } else {
            trailingPresentation(content)
        }
        #else
        trailingPresentation(content)
        #endif
    }

    #if os(iOS)
    private func compactPresentation(_ content: Content) -> some View {
        content
            .blur(radius: coordinator.isPresented ? 2 : 0)
            .disabled(coordinator.isPresented)
            .accessibilityHidden(coordinator.isPresented)
            .sheet(isPresented: compactBinding) {
                NoiroSettingsPanelChrome(coordinator: coordinator) {
                    panelContent()
                }
                .environmentObject(coordinator)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
            }
            .animation(reduceMotion ? nil : Theme.Motion.state, value: coordinator.isPresented)
    }

    private var compactBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isPresented },
            set: { presented in if !presented { coordinator.close() } }
        )
    }
    #endif

    private func trailingPresentation(_ content: Content) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: coordinator.isPresented ? 2 : 0)
                    .disabled(coordinator.isPresented)
                    .accessibilityHidden(coordinator.isPresented)

                if coordinator.isPresented {
                    Color.black.opacity(0.42)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        #if !os(tvOS)
                        .onTapGesture { coordinator.close() }
                        #endif

                    NoiroSettingsPanelChrome(coordinator: coordinator) {
                        panelContent()
                    }
                    .environmentObject(coordinator)
                    .frame(width: panelWidth(for: proxy.size.width))
                    .padding(.vertical, panelInset)
                    .padding(.trailing, panelInset)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.38, dampingFraction: 0.88),
            value: coordinator.isPresented
        )
    }

    private func panelWidth(for width: CGFloat) -> CGFloat {
        #if os(tvOS)
        return width * 0.50
        #elseif os(macOS)
        let fraction = width < 1_000 ? 0.60 : 0.50
        return min(760, max(480, width * fraction))
        #else
        let fraction = width < 900 ? 0.60 : 0.50
        return min(720, max(420, width * fraction))
        #endif
    }

    private var panelInset: CGFloat {
        #if os(tvOS)
        return 28
        #else
        return 12
        #endif
    }
}

extension View {
    func noiroSettingsOverlay<PanelContent: View>(
        coordinator: NoiroSettingsCoordinator,
        @ViewBuilder panelContent: @escaping () -> PanelContent
    ) -> some View {
        modifier(NoiroSettingsOverlayModifier(coordinator: coordinator, panelContent: panelContent))
    }
}
