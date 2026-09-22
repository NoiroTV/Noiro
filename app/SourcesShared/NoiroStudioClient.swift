import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The only native client for Vortexo's isolated Noiro realm.
///
/// Media URLs, plaintext credentials, Apple credentials, local server addresses,
/// downloads, and playback traffic must never be placed in a request made by
/// this type. The personal Noiro document may contain add-on manifests and
/// customer-supplied metadata/debrid keys only after device-side encryption. The
/// server receives device authorization, signed safe configuration, opaque
/// ciphertext, and release metadata; it never receives the recovery key.
struct NoiroStudioClient: Sendable {
    static let productionBaseURL = URL(string: "https://vortexo.app")!

    var baseURL = productionBaseURL
    var session: URLSession = .shared

    struct Capabilities: Codable, Equatable, Sendable {
        struct Pairing: Codable, Equatable, Sendable {
            let ttlSeconds: Int
            let privateVerifierRequired: Bool
            let deviceLimit: Int
        }

        struct Configuration: Codable, Equatable, Sendable {
            let algorithm: String
            let serialization: String
            let publicJwk: PublicJWK?
        }

        struct Vault: Codable, Equatable, Sendable {
            let algorithm: String
            let serverDecryptable: Bool
            let recoveryDays: Int
            let browserWritable: Bool?
            let deviceWritable: Bool?
            let compareAndSwap: Bool?
        }

        struct Dashboard: Codable, Equatable, Sendable {
            let authoritativeSurface: String
            let tabs: [String]
        }

        struct Household: Codable, Equatable, Sendable {
            let supported: Bool
            let serverDecryptable: Bool
            let keyAgreement: String
            let keyDerivation: String
            let wrapping: String
        }

        struct Boundaries: Codable, Equatable, Sendable {
            let mediaHosted: Bool
            let mediaProxied: Bool
            let providerCredentialsAccepted: Bool
            let encryptedCustomerSecretsAccepted: Bool?
            let serverAddressesAccepted: Bool
            let appleCredentialsAccepted: Bool
        }

        let contract: String
        let contractVersion: Int
        let environment: String
        let minimumClientBuild: Int
        let status: String
        let pairing: Pairing
        let configuration: Configuration
        let vault: Vault
        let dashboard: Dashboard?
        let household: Household?
        let boundaries: Boundaries
    }

    struct PublicJWK: Codable, Equatable, Sendable {
        let kty: String
        let x: String
        let y: String
        let crv: String
    }

    struct PairingRequest: Codable, Sendable {
        let displayName: String
        let platform: String
        let environment: String
        let clientBuild: Int
        let verifierChallenge: String
    }

    struct PairingSession: Codable, Equatable, Sendable {
        let contract: String
        let contractVersion: Int
        let userCode: String
        let pollToken: String
        let expiresAt: Int
        let intervalSeconds: Int
        let approveAt: String
    }

    struct PairingPollRequest: Codable, Sendable {
        let pollToken: String
        let verifier: String
    }

    struct PairingClaim: Codable, Equatable, Sendable {
        let contract: String
        let contractVersion: Int
        let status: String
        let accessToken: String
        let deviceId: String
        let accountId: String
    }

    struct ConfigurationEnvelope: Codable, Equatable, Sendable {
        let revision: Int
        let artifact: String?
        let payloadHash: String?
        let signingKeyId: String?
        let createdAt: Int?
    }

    struct SafeConfigurationPayload: Codable, Equatable, Sendable {
        let accountId: String
        let content: [String: JSONValue]
        let contract: String
        let contractVersion: Int
        let environment: String
        let issuedAt: Int
        let minimumClientBuild: Int
        let revision: Int
        let signingKeyId: String
    }

    struct VerifiedConfiguration: Equatable, Sendable {
        let compactJWS: String
        let payload: SafeConfigurationPayload
    }

    struct VaultEnvelope: Codable, Equatable, Sendable {
        let revision: Int?
        let schemaVersion: Int?
        let algorithm: String
        let nonce: String
        let ciphertext: String
        let contentHash: String
        let writerKind: String?
        let updatedAt: Int?
    }

    struct VaultResponse: Codable, Sendable { let vault: VaultEnvelope? }
    struct SyncResponse: Codable, Sendable { let document: VaultEnvelope? }
    struct VaultReceipt: Codable, Sendable {
        let revision: Int
        let contentHash: String
        let idempotent: Bool?
    }

    private struct VaultWrite: Codable, Sendable {
        let expectedRevision: Int
        let schemaVersion: Int?
        let algorithm: String
        let nonce: String
        let ciphertext: String
        let contentHash: String
    }

    enum ClientError: Error, Equatable, Sendable {
        case offline
        case authenticationRequired
        case entitlementRequired(reason: String?)
        case maintenance
        case expired
        case incompatibleClient(minimumBuild: Int?)
        case authorizationPending(retryAfter: Int)
        case authorizationDenied
        case replayed
        case conflict
        case serviceUnavailable(code: String)
        case invalidResponse
        case invalidSignature
        case unsafeConfiguration

        var safeMessage: String {
            switch self {
            case .offline:
                return "Noiro Sync is offline. Your local library and settings still work."
            case .authenticationRequired:
                return "This device is no longer authorized. Pair it again in Vortexo Studio."
            case .entitlementRequired(let reason):
                return reason == "device_limit"
                    ? "Noiro Pro already has five active devices. Revoke one in Studio, then try again."
                    : "Noiro Pro is required for new cloud sync. Your local data is unchanged."
            case .maintenance:
                return "Noiro Sync is paused for maintenance. Your local data is unchanged."
            case .expired:
                return "That device code expired. Create a new code and approve it within ten minutes."
            case .incompatibleClient(let build):
                if let build { return "This Noiro build is too old for Sync. Install build \(build) or newer." }
                return "This Noiro build or environment is not compatible with Sync."
            case .authorizationPending:
                return "Waiting for approval in Vortexo Studio…"
            case .authorizationDenied:
                return "Studio did not approve this device. Create a new code to try again."
            case .replayed:
                return "That approval has already been used. Create a new device code."
            case .conflict:
                return "Studio has a newer configuration. Refresh before saving again."
            case .invalidSignature:
                return "Noiro rejected a configuration whose Studio signature could not be verified."
            case .unsafeConfiguration:
                return "Noiro rejected a configuration containing a private or unsupported setting."
            case .invalidResponse:
                return "Noiro Sync returned an unreadable response. Your local data is unchanged."
            case .serviceUnavailable:
                return "Noiro Sync is not available yet. Your local library and settings still work."
            }
        }
    }

    enum JSONValue: Codable, Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value") }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }

    private struct ErrorEnvelope: Codable {
        struct Details: Codable { let reason: String?; let minimumClientBuild: Int?; let retryAfterSeconds: Int? }
        let code: String
        let message: String?
        let details: Details?
    }

    private struct EmptyBody: Encodable {}

    func capabilities() async throws -> Capabilities {
        try await request("/api/noiro/v1/capabilities", method: "GET", expected: 200, as: Capabilities.self)
    }

    func startPairing(_ body: PairingRequest) async throws -> PairingSession {
        try await request("/api/noiro/v1/pairing/request", method: "POST", body: body, expected: 201, as: PairingSession.self)
    }

    func pollPairing(pollToken: String, verifier: String) async throws -> PairingClaim {
        try await request(
            "/api/noiro/v1/pairing/poll",
            method: "POST",
            body: PairingPollRequest(pollToken: pollToken, verifier: verifier),
            expected: 200,
            as: PairingClaim.self
        )
    }

    func configuration(accessToken: String) async throws -> ConfigurationEnvelope {
        try await request(
            "/api/noiro/v1/config",
            method: "GET",
            bearer: accessToken,
            expected: 200,
            as: ConfigurationEnvelope.self
        )
    }

    func vault(accessToken: String) async throws -> VaultEnvelope? {
        let response = try await request(
            "/api/noiro/v1/vault",
            method: "GET",
            bearer: accessToken,
            expected: 200,
            as: VaultResponse.self
        )
        return response.vault
    }

    func syncDocument(accessToken: String) async throws -> VaultEnvelope? {
        let response = try await request(
            "/api/noiro/v1/sync",
            method: "GET",
            bearer: accessToken,
            expected: 200,
            as: SyncResponse.self
        )
        return response.document
    }

    func putSyncDocument(_ vault: VaultEnvelope, expectedRevision: Int, accessToken: String) async throws -> VaultReceipt {
        try await request(
            "/api/noiro/v1/sync",
            method: "PUT",
            body: VaultWrite(
                expectedRevision: expectedRevision,
                schemaVersion: vault.schemaVersion,
                algorithm: vault.algorithm,
                nonce: vault.nonce,
                ciphertext: vault.ciphertext,
                contentHash: vault.contentHash
            ),
            bearer: accessToken,
            expected: 200,
            as: VaultReceipt.self
        )
    }

    func putVault(_ vault: VaultEnvelope, expectedRevision: Int = 0, accessToken: String) async throws -> VaultReceipt {
        try await putSyncDocument(vault, expectedRevision: expectedRevision, accessToken: accessToken)
    }

    func verifyConfiguration(
        _ envelope: ConfigurationEnvelope,
        capabilities: Capabilities,
        expectedAccountId: String,
        currentBuild: Int
    ) throws -> VerifiedConfiguration? {
        guard envelope.revision > 0 else { return nil }
        guard capabilities.configuration.algorithm == "ES256",
              capabilities.configuration.serialization == "JCS+NFC",
              let jwk = capabilities.configuration.publicJwk,
              let artifact = envelope.artifact else { throw ClientError.invalidSignature }

        let pieces = artifact.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let headerData = Data(base64URLEncoded: String(pieces[0])),
              let payloadData = Data(base64URLEncoded: String(pieces[1])),
              let signatureData = Data(base64URLEncoded: String(pieces[2])),
              signatureData.count == 64,
              let header = try? JSONDecoder().decode(JWSHeader.self, from: headerData),
              let payload = try? JSONDecoder().decode(SafeConfigurationPayload.self, from: payloadData)
        else { throw ClientError.invalidSignature }

        guard header.alg == "ES256", header.typ == "NSC", header.v == 1,
              header.kid == payload.signingKeyId,
              payload.contract == "noiro.safe-configuration",
              payload.contractVersion == 1,
              payload.accountId.caseInsensitiveCompare(expectedAccountId) == .orderedSame,
              payload.environment == capabilities.environment,
              payload.revision == envelope.revision,
              payload.minimumClientBuild <= currentBuild,
              allowedSafeConfiguration(payload.content)
        else {
            if payload.minimumClientBuild > currentBuild {
                throw ClientError.incompatibleClient(minimumBuild: payload.minimumClientBuild)
            }
            throw ClientError.unsafeConfiguration
        }

        guard jwk.kty == "EC", jwk.crv == "P-256",
              let x = Data(base64URLEncoded: jwk.x), x.count == 32,
              let y = Data(base64URLEncoded: jwk.y), y.count == 32 else {
            throw ClientError.invalidSignature
        }
        var point = Data([0x04]); point.append(x); point.append(y)
        let key: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            key = try P256.Signing.PublicKey(x963Representation: point)
            signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        } catch { throw ClientError.invalidSignature }

        let signedData = Data("\(pieces[0]).\(pieces[1])".utf8)
        guard key.isValidSignature(signature, for: signedData) else { throw ClientError.invalidSignature }
        return VerifiedConfiguration(compactJWS: artifact, payload: payload)
    }

    static func newPairingVerifier() -> String {
        let key = SymmetricKey(size: .bits256)
        return Data(key.withUnsafeBytes { Data($0) }).base64URLEncodedString()
    }

    static func verifierChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    static var platformName: String {
        #if os(tvOS)
        return "tvos"
        #elseif os(macOS)
        return "macos"
        #elseif canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #else
        return "ios"
        #endif
    }

    static var deviceDisplayName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return "Noiro device"
        #endif
    }

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
    }

    static func encryptedVault(plaintext: Data, recoveryKey: SymmetricKey) throws -> VaultEnvelope {
        let box = try AES.GCM.seal(plaintext, using: recoveryKey)
        let nonce = box.nonce.withUnsafeBytes { Data($0) }
        var sealed = box.ciphertext
        sealed.append(box.tag)
        var hashInput = nonce
        hashInput.append(sealed)
        let hash = SHA256.hash(data: hashInput).map { String(format: "%02x", $0) }.joined()
        return VaultEnvelope(
            revision: nil,
            schemaVersion: 1,
            algorithm: "A256GCM",
            nonce: nonce.base64URLEncodedString(),
            ciphertext: sealed.base64URLEncodedString(),
            contentHash: hash,
            writerKind: nil,
            updatedAt: nil
        )
    }

    static func decryptVault(_ envelope: VaultEnvelope, recoveryKey: SymmetricKey) throws -> Data {
        guard envelope.algorithm == "A256GCM",
              let nonceData = Data(base64URLEncoded: envelope.nonce), nonceData.count == 12,
              let sealed = Data(base64URLEncoded: envelope.ciphertext), sealed.count > 16 else {
            throw ClientError.invalidResponse
        }
        let ciphertext = sealed.dropLast(16)
        let tag = sealed.suffix(16)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: recoveryKey)
    }

    private struct JWSHeader: Codable {
        let alg: String
        let kid: String
        let typ: String
        let v: Int
    }

    private func allowedSafeConfiguration(_ content: [String: JSONValue]) -> Bool {
        let allowed = Set([
            "appearance", "audio", "homeRows", "kidsMode", "languages", "playback",
            "profiles", "sourceRanking", "subtitles", "updateChannel"
        ])
        guard Set(content.keys).isSubset(of: allowed) else { return false }
        return content.allSatisfy { key, value in safe(value, path: [key]) }
    }

    private func safe(_ value: JSONValue, path: [String]) -> Bool {
        let forbidden = Set([
            "address", "addresses", "credential", "credentials", "debrid", "diagnostic",
            "diagnostics", "download", "downloads", "endpoint", "gemini", "key", "keys",
            "lan", "manifest", "manifests", "password", "passwords", "provider", "secret",
            "secrets", "server", "servers", "token", "tokens", "torrent", "torrents", "url", "urls"
        ])
        if path.contains(where: { forbidden.contains($0.lowercased()) }) { return false }
        switch value {
        case .string(let string):
            return string.count <= 500 && !string.contains("://")
        case .array(let array):
            return array.count <= 100 && array.allSatisfy { safe($0, path: path) }
        case .object(let object):
            guard object.count <= 100 else { return false }
            return object.allSatisfy { key, child in
                let words = key.replacingOccurrences(
                    of: "([a-z0-9])([A-Z])",
                    with: "$1_$2",
                    options: .regularExpression
                ).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                return words.allSatisfy { !forbidden.contains($0) } && safe(child, path: path + words)
            }
        case .bool, .number, .null:
            return true
        }
    }

    private func request<Response: Decodable>(
        _ path: String,
        method: String,
        bearer: String? = nil,
        expected: Int,
        as type: Response.Type
    ) async throws -> Response {
        try await request(path, method: method, body: EmptyBody(), bearer: bearer, expected: expected, as: type, hasBody: false)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Body,
        bearer: String? = nil,
        expected: Int,
        as type: Response.Type,
        hasBody: Bool = true
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if hasBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ClientError.offline }
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard http.statusCode == expected else { throw mapError(status: http.statusCode, data: data) }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ClientError.invalidResponse }
    }

    private func mapError(status: Int, data: Data) -> ClientError {
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let code = envelope?.code ?? "temporarily_unavailable"
        switch code {
        case "service_offline": return .offline
        case "authentication_required": return .authenticationRequired
        case "entitlement_required": return .entitlementRequired(reason: envelope?.details?.reason)
        case "maintenance": return .maintenance
        case "device_code_expired": return .expired
        case "incompatible_client": return .incompatibleClient(minimumBuild: envelope?.details?.minimumClientBuild)
        case "authorization_pending": return .authorizationPending(retryAfter: envelope?.details?.retryAfterSeconds ?? 3)
        case "authorization_denied": return .authorizationDenied
        case "idempotent_replay": return .replayed
        case "conflict", "sync_conflict": return .conflict
        default:
            if status == 401 { return .authenticationRequired }
            if status == 402 { return .entitlementRequired(reason: envelope?.details?.reason) }
            if status == 410 { return .expired }
            if status == 426 { return .incompatibleClient(minimumBuild: envelope?.details?.minimumClientBuild) }
            return .serviceUnavailable(code: code)
        }
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
