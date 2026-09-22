import SwiftUI

/// Noiro's optional Vortexo control-plane connection. There are no reusable
/// passwords here: this device creates a short-lived code and private verifier,
/// Studio approves the code, and only this polling device can claim the token.
struct SyncSettingsView: View {
    @ObservedObject private var sync = NoiroSyncManager.shared
    private let dashboardURL = URL(string: "https://vortexo.app/account?section=noiro&brand=noiro")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                NoiroSettingsPageTitle("Noiro Sync")
                Text("Pair this device with your one Vortexo account. Profiles, library, add-ons, household sharing, service keys, and backups are managed on the encrypted Noiro dashboard.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)

                NoiroPairingView()

                Link(destination: dashboardURL) {
                    Label("Open Noiro dashboard", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(PrimaryActionStyle())

                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    boundary(
                        icon: "checkmark.shield.fill",
                        title: "Website-managed",
                        copy: "Profiles, library, add-ons, household sharing, metadata and debrid keys, Home rows, appearance defaults, encrypted backup, and device revocation."
                    )
                    boundary(
                        icon: "lock.shield.fill",
                        title: "Private on this device",
                        copy: "Apple credentials, raw passwords and PINs, personal-server addresses and logins, playback URLs, media, downloads, caches, torrent controls, LAN sharing, hardware settings, and diagnostics."
                    )
                    boundary(
                        icon: "externaldrive.badge.icloud",
                        title: "Optional zero-knowledge vault",
                        copy: "Backup is encrypted on your device with AES-256-GCM. Vortexo stores ciphertext only and never receives the 256-bit recovery key."
                    )
                }
            }
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.vertical, Theme.Space.xl)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .noiroSettingsPageBackground()
    }

    @ViewBuilder
    private func boundary(icon: String, title: String, copy: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Text(copy).font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

enum NoiroPairingPresentation {
    case settings
    case onboarding
}

struct NoiroPairingView: View {
    @ObservedObject private var sync = NoiroSyncManager.shared
    var autoStart = false
    var presentation: NoiroPairingPresentation = .settings
    var onPaired: (() -> Void)?

    @State private var callbackSent = false
    @State private var recoveryKeyInput = ""
    @State private var revealedRecoveryKey: String?
    @State private var recoveryMessage: String?

    private static let qrSize: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            switch sync.state {
            case .idle:
                statusHeader(icon: "link.badge.plus", title: "This device is not paired", tint: Theme.Palette.textSecondary)
                Text(presentation == .onboarding
                     ? String(localized: "Pair securely with a device-generated code. Your verifier and credentials stay on this device.")
                     : String(localized: "Noiro works locally without an account. Pair only if you want Noiro Pro sync and Studio controls."))
                    .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                Button("Pair with Vortexo Studio") { sync.startPairing() }
                    .buttonStyle(PrimaryActionStyle())

            case .checking:
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text("Checking Noiro Sync…").font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                }

            case .waiting(let code, let expiresAt):
                statusHeader(icon: "tv.badge.wifi", title: "Approve this device in Studio", tint: Theme.Palette.accent)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Theme.Space.lg) {
                        pairingQRCode
                        pairingInstructions(code: code, expiresAt: expiresAt)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        pairingQRCode
                        pairingInstructions(code: code, expiresAt: expiresAt)
                    }
                }

            case .paired:
                statusHeader(icon: "checkmark.circle.fill", title: "Paired with Vortexo", tint: Theme.Palette.accent)
                if sync.lastConfigurationRevision > 0 {
                    Text("Last verified Studio configuration: revision \(sync.lastConfigurationRevision).")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    Text("No Studio configuration has been published yet. Local settings remain active.")
                        .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textSecondary)
                }
                if presentation == .settings {
                    recoveryKeySection
                    HStack(spacing: Theme.Space.sm) {
                        Button("Check website changes") {
                            Task {
                                await sync.refreshVaultStatus()
                                _ = await NoiroDocumentSyncManager.shared.syncDown(force: true)
                                await sync.refreshConfiguration()
                            }
                        }
                            .buttonStyle(PrimaryActionStyle())
                        Button("Disconnect this device") { sync.disconnect() }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }

            case .refreshing:
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text("Verifying Studio configuration…")
                        .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                }

            case .failed(let message):
                statusHeader(icon: "exclamationmark.triangle.fill", title: "Noiro Sync needs attention", tint: Theme.Palette.danger)
                Text(message).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                HStack(spacing: Theme.Space.sm) {
                    Button(sync.isPaired ? "Try again" : "Create a new code") {
                        if sync.isPaired { Task { await sync.refreshConfiguration() } }
                        else { sync.startPairing() }
                    }
                    .buttonStyle(PrimaryActionStyle())
                    if sync.isPaired {
                        Button("Disconnect") { sync.disconnect() }
                            .buttonStyle(ChipButtonStyle(selected: false))
                    }
                }
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .onAppear {
            if autoStart, !sync.isPaired, sync.state == .idle { sync.startPairing() }
            // Reopening an already-connected onboarding card should show its
            // status rather than immediately dismissing. A newly completed
            // pairing still delivers the callback from the state change below.
            if presentation == .onboarding, sync.isPaired { callbackSent = true }
            else { deliverPairedCallbackIfNeeded() }
        }
        #if os(tvOS) || os(macOS)
        .onChange(of: sync.isPaired) { _, paired in
            if paired { deliverPairedCallbackIfNeeded() }
        }
        #else
        .onChange(of: sync.isPaired) { paired in
            if paired { deliverPairedCallbackIfNeeded() }
        }
        #endif
    }

    @ViewBuilder
    private func statusHeader(icon: String, title: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(Theme.Typography.cardTitle)
            .foregroundStyle(tint)
    }

    private func expiryText(_ epoch: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return date.formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder
    private var pairingQRCode: some View {
        if let url = sync.approvalURL, let qr = QRCodeImage.make(url.absoluteString) {
            Image(decorative: qr, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: Self.qrSize, maxHeight: Self.qrSize)
                .padding(Theme.Space.sm)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
    }

    @ViewBuilder
    private func pairingInstructions(code: String, expiresAt: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(code)
                .font(.system(size: 38, weight: .bold, design: .monospaced))
                .tracking(5)
                .foregroundStyle(Theme.Palette.textPrimary)
                .accessibilityLabel("Pairing code \(code)")
            Text("Open vortexo.app/studio/devices, sign in, confirm this exact code, and choose Approve device.")
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
            Text("Expires \(expiryText(expiresAt)). The private verifier stays only in Noiro.")
                .font(Theme.Typography.label).foregroundStyle(Theme.Palette.textTertiary)
            #if !os(tvOS)
            if let approvalURL = sync.approvalURL {
                Link(destination: approvalURL) {
                    Label("Open Studio", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(PrimaryActionStyle())
            }
            #endif
            Button("Cancel") { sync.cancelPairing() }
                .buttonStyle(ChipButtonStyle(selected: false))
        }
    }

    private func deliverPairedCallbackIfNeeded() {
        guard sync.isPaired, !callbackSent else { return }
        callbackSent = true
        onPaired?()
    }

    @ViewBuilder
    private var recoveryKeySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if sync.hasVaultRecoveryKey {
                Label("Encrypted dashboard unlocked on this device", systemImage: "key.fill")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("The recovery key stays in this device's Keychain. Vortexo stores ciphertext only.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button(revealedRecoveryKey == nil ? "Show recovery key" : "Hide recovery key") {
                    revealedRecoveryKey = revealedRecoveryKey == nil ? sync.recoveryKeyForSharing() : nil
                }
                .buttonStyle(ChipButtonStyle(selected: false))
                if let revealedRecoveryKey {
                    Text(revealedRecoveryKey)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if sync.vaultDocumentExists == true {
                Text("Enter the 43-character recovery key from the Noiro dashboard to unlock sync on this device.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                SecureField("Recovery key", text: $recoveryKeyInput)
                    .autocorrectionDisabled()
                Button("Unlock encrypted dashboard") {
                    if sync.importVaultRecoveryKey(recoveryKeyInput) {
                        recoveryKeyInput = ""
                        recoveryMessage = "Recovery key saved on this device."
                        Task { _ = await NoiroDocumentSyncManager.shared.syncDown(force: true) }
                    } else {
                        recoveryMessage = "That recovery key is not valid."
                    }
                }
                .buttonStyle(PrimaryActionStyle())
            } else if sync.vaultDocumentExists == false {
                Text("No encrypted dashboard exists yet. Create its recovery key here, save it, then enter the same key in the website.")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button("Create recovery key") {
                    revealedRecoveryKey = sync.createVaultRecoveryKeyIfNeeded()
                    recoveryMessage = revealedRecoveryKey == nil ? "A recovery key already exists on this device." : "Save this key before leaving this screen."
                }
                .buttonStyle(PrimaryActionStyle())
            } else {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text("Checking encrypted dashboard…")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            if let recoveryMessage {
                Text(recoveryMessage)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(Theme.Space.sm)
        .background(Theme.Palette.surface2, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
