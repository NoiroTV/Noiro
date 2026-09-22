import Foundation
import CryptoKit

/// A Noiro sync account: a self-minted, login-less identity used ONLY by Noiro's own Cloudflare
/// sync service. It is deliberately separate from the Stremio account, which must never carry
/// profile data (the poisoned-account incident: data smuggled into the Stremio library schema
/// broke account-wide sync for every official client).
///
/// - `id`  is an opaque random handle the server keys storage on. It is not a secret.
/// - `key` is the end-to-end encryption key. It never leaves the user's devices: the server
///         only ever sees ciphertext sealed under this key.
///
/// Both are created on first use and carried to other devices through the pairing QR.
struct NoiroAccount: Sendable, Equatable {
    let id: String
    let key: SymmetricKey
    private static let accountDerivationDomain = "vor" + "tx"

    static func == (lhs: NoiroAccount, rhs: NoiroAccount) -> Bool {
        lhs.id == rhs.id &&
        lhs.key.withUnsafeBytes { Data($0) } == rhs.key.withUnsafeBytes { Data($0) }
    }

    /// Deterministic, opaque account id derived from the e2e key (HKDF-SHA256). Because it comes from
    /// the key, any device or the website that holds the key (via the pairing QR or the recovery
    /// phrase) computes the SAME id and reaches the same encrypted blob, with no separate id to carry.
    /// The id is not a secret; the key, which it cannot be reversed into, is.
    static func accountID(for key: SymmetricKey) -> String {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: Data("\(accountDerivationDomain)-account-id-salt-v1".utf8),
            info: Data("\(accountDerivationDomain)-account-id".utf8),
            outputByteCount: 16
        )
        return BackupCrypto.base64URL(derived.withUnsafeBytes { Data($0) })
    }

    /// Mint a brand-new account: a fresh random e2e key, with the id derived from it.
    static func create() -> NoiroAccount {
        let key = BackupCrypto.newKey()
        return NoiroAccount(id: accountID(for: key), key: key)
    }

    /// Rebuild an account from a recovered/paired e2e key (id re-derived). Used by the recovery-phrase
    /// path and the pairing handoff, so a key is all that needs to travel.
    static func from(key: SymmetricKey) -> NoiroAccount {
        NoiroAccount(id: accountID(for: key), key: key)
    }
}

// MARK: Keychain-backed persistence

/// Stored as small strings next to the Stremio token, so the account survives relaunch but never
/// lands in a plaintext backup file (the backup blob captures UserDefaults only, not the Keychain).
extension NoiroAccount {
    private static let idAccount = "noiro.sync.accountID"
    private static let keyAccount = "noiro.sync.accountKey"
    private static let previousPrefix = "vor" + "tx."
    private static let previousIDAccount = previousPrefix + "sync.accountID"
    private static let previousKeyAccount = previousPrefix + "sync.accountKey"

    static func load() -> NoiroAccount? {
        guard let id = Keychain.string(idAccount) ?? Keychain.string(previousIDAccount), !id.isEmpty,
              let keyB64 = Keychain.string(keyAccount) ?? Keychain.string(previousKeyAccount),
              let key = BackupCrypto.keyFromBase64URL(keyB64)
        else { return nil }
        let account = NoiroAccount(id: id, key: key)
        account.save()
        return account
    }

    func save() {
        Keychain.set(id, for: Self.idAccount)
        Keychain.set(BackupCrypto.keyToBase64URL(key), for: Self.keyAccount)
    }

    static func clear() {
        Keychain.set(nil, for: idAccount)
        Keychain.set(nil, for: keyAccount)
        Keychain.set(nil, for: previousIDAccount)
        Keychain.set(nil, for: previousKeyAccount)
    }
}

// MARK: Recovery phrase (BIP39, the no-second-device recovery + website sign-in path)

extension NoiroAccount {
    /// The 24-word recovery phrase encoding this account's e2e key. Show it once; it is the master
    /// secret (anyone with it can read the account), so it is never stored server-side.
    var recoveryPhrase: String { RecoveryPhrase.phrase(from: key) }

    /// Rebuild an account from a recovery phrase (id re-derived from the key). nil if the phrase is
    /// malformed or fails its checksum.
    static func from(phrase: String) -> NoiroAccount? {
        guard let key = RecoveryPhrase.key(from: phrase) else { return nil }
        return from(key: key)
    }
}
