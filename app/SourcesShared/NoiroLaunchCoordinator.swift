import SwiftUI

/// Versioned, device-local onboarding state. Classification deliberately runs
/// before the older settings migration writes its marker, so an interrupted
/// fresh install cannot turn into an "existing" install on its second launch.
enum NoiroOnboardingPersistence {
    static let bootstrapKey = "noiro.onboarding.bootstrap.v1"
    static let completedVersionKey = "noiro.onboarding.completedVersion"
    static let currentVersion = 1

    static var isComplete: Bool {
        UserDefaults.standard.integer(forKey: completedVersionKey) >= currentVersion
    }

    static func prepareForLaunch() {
        prepareForLaunch(
            defaults: .standard,
            settingsMigrationHadRun: NoiroSettingsMigration.hasRun
        )
    }

    /// Kept parameterized so clean, interrupted, and upgrade classification can
    /// be verified without touching a user's real defaults domain.
    static func prepareForLaunch(defaults: UserDefaults, settingsMigrationHadRun: Bool) {
        guard defaults.object(forKey: bootstrapKey) == nil else { return }
        defaults.set(true, forKey: bootstrapKey)
        if settingsMigrationHadRun {
            defaults.set(currentVersion, forKey: completedVersionKey)
        }
    }

    static func markComplete() {
        UserDefaults.standard.set(currentVersion, forKey: completedVersionKey)
    }
}

@MainActor
final class NoiroLaunchCoordinator: ObservableObject {
    enum OnboardingStep: Int, CaseIterable, Equatable {
        case welcome
        case library
        case ready
    }

    enum OnboardingOrigin: Equatable {
        case firstInstall
        case settingsReplay
    }

    enum Phase: Equatable {
        case dormant
        case brandReveal(NoiroSplashPresentation)
        case onboarding(OnboardingOrigin)
        case interactiveContent
    }

    @Published private(set) var phase: Phase = .dormant
    @Published private(set) var onboardingStep: OnboardingStep = .welcome

    var isContentInteractive: Bool {
        phase == .interactiveContent
    }

    var onboardingOrigin: OnboardingOrigin? {
        guard case .onboarding(let origin) = phase else { return nil }
        return origin
    }

    func start() {
        guard phase == .dormant else { return }
        phase = .brandReveal(NoiroOnboardingPersistence.isComplete ? .returning : .firstInstall)
    }

    func brandRevealFinished() {
        guard case .brandReveal = phase else { return }
        if NoiroOnboardingPersistence.isComplete {
            phase = .interactiveContent
        } else {
            onboardingStep = .welcome
            phase = .onboarding(.firstInstall)
        }
    }

    func setUpNoiro() {
        guard onboardingOrigin != nil else { return }
        onboardingStep = .library
    }

    func reviewReadiness() {
        guard onboardingOrigin != nil else { return }
        onboardingStep = .ready
    }

    func goBack() {
        guard let origin = onboardingOrigin else { return }
        switch onboardingStep {
        case .ready:
            onboardingStep = .library
        case .library:
            onboardingStep = .welcome
        case .welcome:
            if origin == .settingsReplay { phase = .interactiveContent }
        }
    }

    func enterNoiro() {
        guard onboardingOrigin != nil else { return }
        NoiroOnboardingPersistence.markComplete()
        phase = .interactiveContent
    }

    func replayFromSettings() {
        guard phase == .interactiveContent else { return }
        onboardingStep = .welcome
        phase = .onboarding(.settingsReplay)
    }

    func closeReplay() {
        guard onboardingOrigin == .settingsReplay else { return }
        phase = .interactiveContent
    }
}

/// Owns all launch presentation above the permanently-mounted app shell. The
/// engine and embedded server keep warming underneath, while content remains
/// hidden and disabled until the coordinator explicitly makes it interactive.
struct NoiroLaunchExperienceView<Content: View>: View {
    @EnvironmentObject private var launch: NoiroLaunchCoordinator
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()

            content
                .opacity(launch.isContentInteractive ? 1 : 0)
                .disabled(!launch.isContentInteractive)
                .accessibilityHidden(!launch.isContentInteractive)

            switch launch.phase {
            case .dormant:
                NoiroPrismaticBackdrop()
                    .transition(.opacity)
            case .brandReveal(let presentation):
                SplashView(presentation: presentation) {
                    launch.brandRevealFinished()
                }
                .id(presentation)
                .transition(.opacity)
            case .onboarding:
                NoiroOnboardingView()
                    .transition(.opacity)
            case .interactiveContent:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.32), value: launch.phase)
        .onAppear { launch.start() }
    }
}

private enum NoiroOnboardingDestination: String, Identifiable {
    case noiroSync
    case stremio

    var id: String { rawValue }
}

/// Shared three-stage setup journey. It reports existing live state instead of
/// keeping a second onboarding-only model, so pairing and imports survive app
/// termination and can be completed in either order.
private struct NoiroOnboardingView: View {
    @EnvironmentObject private var launch: NoiroLaunchCoordinator
    @EnvironmentObject private var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var sync = NoiroSyncManager.shared
    @State private var destination: NoiroOnboardingDestination?

    #if os(tvOS)
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 64
    private let maximumWidth: CGFloat = 1360
    #else
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 42
    private let maximumWidth: CGFloat = 980
    #endif

    private var hasConnectedService: Bool {
        sync.isPaired || account.isSignedIn
    }

    var body: some View {
        presentedJourney
    }

    @ViewBuilder
    private var presentedJourney: some View {
        #if os(macOS)
        journey
            .sheet(item: $destination) { setupDestination($0) }
        #else
        journey
            .fullScreenCover(item: $destination) { setupDestination($0) }
        #endif
    }

    private var journey: some View {
        GeometryReader { proxy in
            ZStack {
                NoiroPrismaticBackdrop()

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        journeyHeader
                        stepProgress
                        stepContent
                    }
                    .padding(.horizontal, Theme.Space.screenInset)
                    .padding(.vertical, Theme.Space.lg)
                    .frame(maxWidth: maximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                }
                .scrollIndicators(.hidden)
            }
        }
        #if os(tvOS) || os(macOS)
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn, destination == .stremio { destination = nil }
        }
        #else
        .onChange(of: account.isSignedIn) { signedIn in
            if signedIn, destination == .stremio { destination = nil }
        }
        #endif
        #if os(tvOS)
        .onExitCommand(perform: exitCommand)
        #endif
    }

    #if os(tvOS)
    private var exitCommand: (() -> Void)? {
        if launch.onboardingOrigin == .settingsReplay, launch.onboardingStep == .welcome {
            return { launch.closeReplay() }
        }
        if launch.onboardingStep != .welcome {
            return { launch.goBack() }
        }
        return nil
    }
    #endif

    private var journeyHeader: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            NoiroWordmark(fontSize: 30)
            Spacer(minLength: Theme.Space.md)
            if launch.onboardingStep != .welcome {
                Button { launch.goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
            }
            if launch.onboardingOrigin == .settingsReplay {
                Button { launch.closeReplay() } label: {
                    Label("Close setup", systemImage: "xmark")
                }
                .buttonStyle(ChipButtonStyle(selected: false))
            }
        }
    }

    private var stepProgress: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(NoiroLaunchCoordinator.OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= launch.onboardingStep.rawValue ? Theme.Palette.accent : Color.white.opacity(0.16))
                    .frame(width: step == launch.onboardingStep ? 52 : 24, height: 5)
            }
        }
        .animation(Theme.Motion.state, value: launch.onboardingStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Setup step \(launch.onboardingStep.rawValue + 1) of 3")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch launch.onboardingStep {
        case .welcome:
            welcomeStep
        case .library:
            libraryStep
        case .ready:
            readyStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Your media. Beautifully yours.")
                    .font(.system(size: titleSize, weight: .heavy, design: .serif))
                    .tracking(-1)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Noiro plays directly from libraries and sources you choose. Your source credentials stay on this device, and an account is always optional.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 780, alignment: .leading)
            }

            Button("Set up Noiro") { launch.setUpNoiro() }
                .buttonStyle(PrimaryActionStyle())
                .accessibilityHint("Moves to library connection options")

            Group {
                if horizontalSizeClass == .compact {
                    VStack(spacing: Theme.Space.md) { welcomeFeatures }
                } else {
                    HStack(spacing: Theme.Space.md) { welcomeFeatures }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Space.lg)
    }

    @ViewBuilder
    private var welcomeFeatures: some View {
        welcomeFeature(icon: "play.rectangle.fill", title: "Direct playback", copy: "Noiro connects to your sources without hosting your media.")
        welcomeFeature(icon: "rectangle.stack.person.crop.fill", title: "Your libraries", copy: "Bring the collection and history that already belong to you.")
        welcomeFeature(icon: "lock.shield.fill", title: "Device-local privacy", copy: "Passwords and source credentials remain under your control.")
    }

    @ViewBuilder
    private func welcomeFeature(icon: String, title: LocalizedStringKey, copy: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(copy)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var libraryStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Bring your library.")
                    .font(.system(size: titleSize, weight: .heavy, design: .serif))
                    .tracking(-1)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Connect either service, or both. You can return here after each one and see its live status before continuing.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if horizontalSizeClass == .compact {
                VStack(spacing: Theme.Space.md) { setupCards }
            } else {
                HStack(alignment: .top, spacing: Theme.Space.md) { setupCards }
            }

            if hasConnectedService {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.sm) { libraryActions }
                    VStack(alignment: .leading, spacing: Theme.Space.sm) { libraryActions }
                }
            } else {
                Button("Continue locally") { launch.reviewReadiness() }
                    .buttonStyle(ChipButtonStyle(selected: false))
            }

            Text("Continue locally never requires an account or repeats this prompt. Playback still requires at least one compatible source or stream add-on.")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Space.md)
    }

    @ViewBuilder
    private var libraryActions: some View {
        Button("Review setup") { launch.reviewReadiness() }
            .buttonStyle(PrimaryActionStyle())
        Button("Continue locally") { launch.reviewReadiness() }
            .buttonStyle(ChipButtonStyle(selected: false))
    }

    @ViewBuilder
    private var setupCards: some View {
        setupCard(
            icon: "point.3.connected.trianglepath.dotted",
            title: "Pair Noiro Sync",
            copy: "Restore published encrypted configuration and sync supported Noiro data.",
            isConnected: sync.isPaired,
            connectedText: "Connected"
        ) { destination = .noiroSync }

        setupCard(
            icon: "arrow.down.doc.fill",
            title: "Import from Stremio",
            copy: "Bring across your add-ons, library, and watch history using QR or password sign-in.",
            isConnected: account.isSignedIn,
            connectedText: "Imported"
        ) { destination = .stremio }
    }

    private func setupCard(
        icon: String,
        title: LocalizedStringKey,
        copy: LocalizedStringKey,
        isConnected: Bool,
        connectedText: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        let actionTitle: LocalizedStringKey = isConnected ? "Manage connection" : "Start setup"
        let accessibilityHint: LocalizedStringKey = isConnected ? "Opens connection details" : "Starts this connection"
        return Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Spacer(minLength: Theme.Space.sm)
                    if isConnected {
                        Label(connectedText, systemImage: "checkmark.circle.fill")
                            .font(Theme.Typography.eyebrow)
                            .foregroundStyle(Theme.Palette.ok)
                    }
                }
                Text(title)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(copy)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Label(actionTitle, systemImage: "arrow.right")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .padding(Theme.Space.lg)
            .frame(maxWidth: .infinity, minHeight: 245, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(RowFocusStyle())
        .accessibilityHint(accessibilityHint)
    }

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Your Noiro is ready.")
                    .font(.system(size: titleSize, weight: .heavy, design: .serif))
                    .tracking(-1)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(readinessSummary)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                readinessRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Noiro Sync",
                    value: sync.isPaired ? "Connected" : "Not connected",
                    ready: sync.isPaired
                )
                readinessDivider
                readinessRow(
                    icon: "arrow.down.doc.fill",
                    title: "Stremio",
                    value: account.isSignedIn ? "Imported" : "Not connected",
                    ready: account.isSignedIn
                )
                readinessDivider
                readinessRow(
                    icon: "books.vertical.fill",
                    title: "Library",
                    value: libraryStatus,
                    ready: libraryItemCount > 0
                )
                readinessDivider
                readinessRow(
                    icon: "play.rectangle.on.rectangle.fill",
                    title: "Stream add-ons",
                    value: streamAddonStatus,
                    ready: streamAddonCount > 0
                )
            }
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }

            Button("Enter Noiro") { launch.enterNoiro() }
                .buttonStyle(PrimaryActionStyle())
                .accessibilityHint("Completes setup and opens Home")
        }
        .padding(.vertical, Theme.Space.md)
    }

    private var readinessSummary: String {
        if streamAddonCount > 0 {
            return String(localized: "Your connected sources are available. You can adjust every option later in Settings.")
        }
        return String(localized: "Local mode is ready. Add a compatible source or stream add-on before starting playback.")
    }

    private var libraryItemCount: Int { core.library?.catalog.count ?? 0 }
    private var streamAddonCount: Int { core.addons.filter(\.providesStreams).count }

    private var libraryStatus: String {
        libraryItemCount == 1
            ? String(localized: "1 item available")
            : String.localizedStringWithFormat(String(localized: "%lld items available"), libraryItemCount)
    }

    private var streamAddonStatus: String {
        streamAddonCount == 1
            ? String(localized: "1 add-on available")
            : String.localizedStringWithFormat(String(localized: "%lld add-ons available"), streamAddonCount)
    }

    @ViewBuilder
    private func readinessRow(icon: String, title: LocalizedStringKey, value: String, ready: Bool) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ready ? Theme.Palette.accent : Theme.Palette.textTertiary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(value)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer(minLength: Theme.Space.md)
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(ready ? Theme.Palette.ok : Theme.Palette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.md)
        .accessibilityElement(children: .combine)
    }

    private var readinessDivider: some View {
        Divider().overlay(Color.white.opacity(0.08)).padding(.leading, 72)
    }

    @ViewBuilder
    private func setupDestination(_ value: NoiroOnboardingDestination) -> some View {
        switch value {
        case .noiroSync:
            ZStack {
                NoiroPrismaticBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        HStack {
                            NoiroWordmark(fontSize: 28)
                            Spacer()
                            Button("Back to setup") { destination = nil }
                                .buttonStyle(ChipButtonStyle(selected: false))
                        }
                        Text("Pair Noiro Sync")
                            .font(.system(size: titleSize, weight: .heavy, design: .serif))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        NoiroPairingView(autoStart: true, presentation: .onboarding) {
                            Task { _ = await NoiroDocumentSyncManager.shared.syncDown(force: true) }
                            destination = nil
                        }
                    }
                    .padding(Theme.Space.screenInset)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 620)
            #endif

        case .stremio:
            #if os(tvOS)
            ZStack(alignment: .topLeading) {
                LoginView(account: account, initialMode: .stremioLink)
                Button("Back to setup") { destination = nil }
                    .buttonStyle(ChipButtonStyle(selected: false))
                    .padding(Theme.Space.screenInset)
            }
            #else
            iOSSignInView()
                #if os(macOS)
                .frame(minWidth: 660, minHeight: 620)
                #endif
            #endif
        }
    }
}
