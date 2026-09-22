import CryptoKit
import Foundation

/// Optional Noiro Sync state. Local playback and settings never depend on this
/// object, so every error path leaves the base app usable and preserves the last
/// verified safe configuration.
@MainActor
final class NoiroSyncManager: ObservableObject {
    static let shared = NoiroSyncManager()

    enum State: Equatable {
        case idle
        case checking
        case waiting(code: String, expiresAt: Int)
        case paired
        case refreshing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isPaired = false
    @Published private(set) var lastGoodConfiguration: NoiroStudioClient.SafeConfigurationPayload?
    @Published private(set) var lastConfigurationRevision = 0
    @Published private(set) var vaultDocumentExists: Bool?

    private struct DeviceAuthorization: Codable {
        let accessToken: String
        let deviceId: String
        let accountId: String
    }

    private static let deviceAuthorizationKey = "noiro.sync.device-authorization.v1"
    private static let cachedConfigurationKey = "noiro.sync.last-good-configuration.v1"
    private static let cachedArtifactKey = "noiro.sync.last-good-artifact.v1"
    private static let vaultRecoveryKey = "noiro.sync.vault-recovery-key.v1"

    private let client: NoiroStudioClient
    private var authorization: DeviceAuthorization?
    private var capabilities: NoiroStudioClient.Capabilities?
    private var pairingTask: Task<Void, Never>?

    private init(client: NoiroStudioClient = NoiroStudioClient()) {
        self.client = client
        restoreAuthorization()
        restoreLastGoodConfiguration()
        state = isPaired ? .paired : .idle
    }

    deinit { pairingTask?.cancel() }

    var userCode: String? {
        if case .waiting(let code, _) = state { return code }
        return nil
    }

    var approvalURL: URL? {
        guard let code = userCode else { return nil }
        var components = URLComponents(string: "https://vortexo.app/studio/devices")
        components?.queryItems = [URLQueryItem(name: "noiro", value: code)]
        return components?.url
    }

    var hasVaultRecoveryKey: Bool { Keychain.string(Self.vaultRecoveryKey) != nil }
    var pairedAccountId: String? { authorization?.accountId }

    /// Internal handoff used by the legacy merge engine while it is being
    /// retained as Noiro's local document reconciler. The token and key never
    /// leave this process and are never copied into UserDefaults.
    var syncIdentity: (accessToken: String, accountId: String, recoveryKey: Data?)? {
        guard let authorization else { return nil }
        return (authorization.accessToken, authorization.accountId, recoveryKeyData())
    }

    func startPairing() {
        pairingTask?.cancel()
        state = .checking
        pairingTask = Task { [weak self] in await self?.pair() }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        state = isPaired ? .paired : .idle
    }

    func disconnect() {
        pairingTask?.cancel()
        pairingTask = nil
        authorization = nil
        isPaired = false
        vaultDocumentExists = nil
        Keychain.set(nil, for: Self.deviceAuthorizationKey)
        // Keep the last verified safe configuration: Pro expiry or a temporary
        // disconnection must not erase local state or make the base app unusable.
        state = .idle
        NotificationCenter.default.post(name: .noiroDeviceAuthorizationDidChange, object: nil)
    }

    func refreshConfiguration() async {
        guard let authorization else {
            state = .failed(NoiroStudioClient.ClientError.authenticationRequired.safeMessage)
            return
        }
        state = .refreshing
        do {
            let caps = try await currentCapabilities()
            let envelope = try await client.configuration(accessToken: authorization.accessToken)
            guard let verified = try client.verifyConfiguration(
                envelope,
                capabilities: caps,
                expectedAccountId: authorization.accountId,
                currentBuild: NoiroStudioClient.currentBuild
            ) else {
                state = .paired
                return
            }
            cache(verified)
            NoiroSafeSettingsApplier.apply(verified.payload.content)
            state = .paired
        } catch let error as NoiroStudioClient.ClientError {
            if error == .authenticationRequired {
                self.authorization = nil
                isPaired = false
                Keychain.set(nil, for: Self.deviceAuthorizationKey)
            }
            state = .failed(error.safeMessage)
        } catch {
            state = .failed(NoiroStudioClient.ClientError.invalidResponse.safeMessage)
        }
    }

    /// Returns a newly-created recovery key only once. The key is generated and
    /// retained on this device; no request transports it to Vortexo.
    func createVaultRecoveryKeyIfNeeded() -> String? {
        guard vaultDocumentExists != true else { return nil }
        if Keychain.string(Self.vaultRecoveryKey) != nil { return nil }
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0).noiroBase64URL }
        Keychain.set(encoded, for: Self.vaultRecoveryKey)
        NotificationCenter.default.post(name: .noiroDeviceAuthorizationDidChange, object: nil)
        return encoded
    }

    @discardableResult
    func importVaultRecoveryKey(_ encoded: String) -> Bool {
        let trimmed = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(noiroBase64URL: trimmed), data.count == 32 else { return false }
        Keychain.set(trimmed, for: Self.vaultRecoveryKey)
        NotificationCenter.default.post(name: .noiroDeviceAuthorizationDidChange, object: nil)
        return true
    }

    func recoveryKeyForSharing() -> String? { Keychain.string(Self.vaultRecoveryKey) }

    func refreshVaultStatus() async {
        guard let authorization else {
            vaultDocumentExists = nil
            return
        }
        do {
            vaultDocumentExists = try await client.syncDocument(accessToken: authorization.accessToken) != nil
        } catch {
            vaultDocumentExists = nil
        }
    }

    func dashboardRevision() async throws -> Int {
        guard let authorization else { throw NoiroStudioClient.ClientError.authenticationRequired }
        return try await client.syncDocument(accessToken: authorization.accessToken)?.revision ?? 0
    }

    func uploadEncryptedVault(_ plaintext: Data) async throws {
        guard let authorization else { throw NoiroStudioClient.ClientError.authenticationRequired }
        let key = try recoveryKey()
        let envelope = try NoiroStudioClient.encryptedVault(plaintext: plaintext, recoveryKey: key)
        let current = try await client.syncDocument(accessToken: authorization.accessToken)
        _ = try await client.putSyncDocument(
            envelope,
            expectedRevision: current?.revision ?? 0,
            accessToken: authorization.accessToken
        )
        vaultDocumentExists = true
    }

    func downloadDecryptedVault(recoveryKey override: String? = nil) async throws -> Data? {
        guard let authorization else { throw NoiroStudioClient.ClientError.authenticationRequired }
        let key = try recoveryKey(override: override)
        guard let envelope = try await client.vault(accessToken: authorization.accessToken) else { return nil }
        return try NoiroStudioClient.decryptVault(envelope, recoveryKey: key)
    }

    struct DashboardDocument {
        let revision: Int
        let value: [String: Any]
    }

    func pullDashboardDocument() async throws -> DashboardDocument? {
        guard let authorization else { throw NoiroStudioClient.ClientError.authenticationRequired }
        let key = try recoveryKey()
        guard let envelope = try await client.syncDocument(accessToken: authorization.accessToken) else {
            vaultDocumentExists = false
            return nil
        }
        let plaintext = try NoiroStudioClient.decryptVault(envelope, recoveryKey: key)
        guard let value = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw NoiroStudioClient.ClientError.invalidResponse
        }
        vaultDocumentExists = true
        return DashboardDocument(revision: envelope.revision ?? 0, value: value)
    }

    func pushDashboardDocument(_ value: [String: Any], expectedRevision: Int) async throws -> Int {
        guard let authorization else { throw NoiroStudioClient.ClientError.authenticationRequired }
        guard JSONSerialization.isValidJSONObject(value) else { throw NoiroStudioClient.ClientError.invalidResponse }
        let plaintext = try JSONSerialization.data(withJSONObject: value)
        let envelope = try NoiroStudioClient.encryptedVault(plaintext: plaintext, recoveryKey: try recoveryKey())
        let receipt = try await client.putSyncDocument(
            envelope,
            expectedRevision: expectedRevision,
            accessToken: authorization.accessToken
        )
        vaultDocumentExists = true
        return receipt.revision
    }

    private func pair() async {
        do {
            let caps = try await client.capabilities()
            capabilities = caps
            guard caps.status == "available" else {
                if caps.status == "maintenance" { throw NoiroStudioClient.ClientError.maintenance }
                throw NoiroStudioClient.ClientError.serviceUnavailable(code: caps.status)
            }
            guard NoiroStudioClient.currentBuild >= caps.minimumClientBuild else {
                throw NoiroStudioClient.ClientError.incompatibleClient(minimumBuild: caps.minimumClientBuild)
            }
            guard caps.pairing.privateVerifierRequired else {
                throw NoiroStudioClient.ClientError.serviceUnavailable(code: "private_verifier_required")
            }

            let verifier = NoiroStudioClient.newPairingVerifier()
            let pairing = try await client.startPairing(.init(
                displayName: NoiroStudioClient.deviceDisplayName,
                platform: NoiroStudioClient.platformName,
                environment: caps.environment,
                clientBuild: NoiroStudioClient.currentBuild,
                verifierChallenge: NoiroStudioClient.verifierChallenge(verifier)
            ))
            state = .waiting(code: pairing.userCode, expiresAt: pairing.expiresAt)
            await poll(pairing, verifier: verifier)
        } catch is CancellationError {
            return
        } catch let error as NoiroStudioClient.ClientError {
            state = .failed(error.safeMessage)
        } catch {
            state = .failed(NoiroStudioClient.ClientError.invalidResponse.safeMessage)
        }
    }

    private func poll(_ pairing: NoiroStudioClient.PairingSession, verifier: String) async {
        var delay = max(pairing.intervalSeconds, 2)
        while !Task.isCancelled {
            if Int(Date().timeIntervalSince1970) >= pairing.expiresAt {
                state = .failed(NoiroStudioClient.ClientError.expired.safeMessage)
                return
            }
            do {
                let claim = try await client.pollPairing(pollToken: pairing.pollToken, verifier: verifier)
                guard claim.status == "paired" else { throw NoiroStudioClient.ClientError.invalidResponse }
                let saved = DeviceAuthorization(
                    accessToken: claim.accessToken,
                    deviceId: claim.deviceId,
                    accountId: claim.accountId
                )
                persist(saved)
                state = .paired
                await refreshVaultStatus()
                await refreshConfiguration()
                return
            } catch let error as NoiroStudioClient.ClientError {
                if case .authorizationPending(let retryAfter) = error {
                    delay = max(retryAfter, 2)
                } else {
                    state = .failed(error.safeMessage)
                    return
                }
            } catch {
                state = .failed(NoiroStudioClient.ClientError.offline.safeMessage)
                return
            }

            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
        }
    }

    private func currentCapabilities() async throws -> NoiroStudioClient.Capabilities {
        if let capabilities { return capabilities }
        let fetched = try await client.capabilities()
        capabilities = fetched
        return fetched
    }

    private func persist(_ value: DeviceAuthorization) {
        guard let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) else { return }
        authorization = value
        isPaired = true
        Keychain.set(encoded, for: Self.deviceAuthorizationKey)
        NotificationCenter.default.post(name: .noiroDeviceAuthorizationDidChange, object: nil)
    }

    private func restoreAuthorization() {
        guard let encoded = Keychain.string(Self.deviceAuthorizationKey),
              let data = encoded.data(using: .utf8),
              let value = try? JSONDecoder().decode(DeviceAuthorization.self, from: data),
              value.accessToken.hasPrefix("noiro_") else { return }
        authorization = value
        isPaired = true
        Task { [weak self] in await self?.refreshVaultStatus() }
    }

    private func cache(_ verified: NoiroStudioClient.VerifiedConfiguration) {
        guard let data = try? JSONEncoder().encode(verified.payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedConfigurationKey)
        UserDefaults.standard.set(verified.compactJWS, forKey: Self.cachedArtifactKey)
        lastGoodConfiguration = verified.payload
        lastConfigurationRevision = verified.payload.revision
        NotificationCenter.default.post(name: .noiroSafeConfigurationDidChange, object: nil)
    }

    private func restoreLastGoodConfiguration() {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedConfigurationKey),
              let payload = try? JSONDecoder().decode(NoiroStudioClient.SafeConfigurationPayload.self, from: data) else { return }
        lastGoodConfiguration = payload
        lastConfigurationRevision = payload.revision
    }

    private func recoveryKey(override: String? = nil) throws -> SymmetricKey {
        let encoded = override ?? Keychain.string(Self.vaultRecoveryKey)
        guard let encoded, let data = Data(noiroBase64URL: encoded), data.count == 32 else {
            throw NoiroStudioClient.ClientError.authenticationRequired
        }
        return SymmetricKey(data: data)
    }

    private func recoveryKeyData() -> Data? {
        guard let encoded = Keychain.string(Self.vaultRecoveryKey),
              let data = Data(noiroBase64URL: encoded), data.count == 32 else { return nil }
        return data
    }
}

extension Notification.Name {
    static let noiroSafeConfigurationDidChange = Notification.Name("noiro.safeConfigurationDidChange")
    static let noiroDeviceAuthorizationDidChange = Notification.Name("noiro.deviceAuthorizationDidChange")
}

/// Applies only a narrow, documented subset of the signed safe document. All
/// unknown values remain cached but inert until a typed mapper is added.
@MainActor
enum NoiroSafeSettingsApplier {
    static func apply(_ content: [String: NoiroStudioClient.JSONValue]) {
        if case .object(let appearance)? = content["appearance"] {
            if case .string(let accent)? = appearance["accent"],
               ThemeManager.accents.contains(where: { $0.id == accent }) {
                ThemeManager.shared.accentID = accent
            }
            if case .bool(let oled)? = appearance["oled"] {
                ThemeManager.shared.oled = oled
            }
            if case .number(let scale)? = appearance["textScale"],
               ThemeManager.textScaleRange.contains(scale) {
                ThemeManager.shared.textScale = scale
            }
        }
        if case .object(let languages)? = content["languages"],
           case .string(let appLanguage)? = languages["app"],
           appLanguage == "system" || AppLanguage.supported.contains(where: { $0.code == appLanguage }) {
            AppLanguage.set(appLanguage == "system" ? nil : appLanguage)
        }
        if case .string(let channel)? = content["updateChannel"],
           ["stable", "preview"].contains(channel) {
            UserDefaults.standard.set(channel, forKey: "noiro.updateChannel")
        }
    }
}

private extension Data {
    init?(noiroBase64URL value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

    var noiroBase64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
