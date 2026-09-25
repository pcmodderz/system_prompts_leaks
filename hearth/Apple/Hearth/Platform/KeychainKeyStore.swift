import CryptoKit
import Foundation
import HearthCore
import LocalAuthentication
import Security

/// Root keys in the iOS Keychain, never in the app bundle, never in iCloud Keychain.
///
/// - household: `AfterFirstUnlockThisDeviceOnly` so background refresh and inbox filing work
///   while the phone is locked after it has been unlocked once since boot.
/// - vault: wrapped by a Secure Enclave P-256 key that requires user presence (Face ID /
///   Touch ID / passcode) for every unwrap. The wrapped blob is useless on any other device.
///   Falls back to a Keychain item with a `.userPresence` access control when the Secure
///   Enclave is unavailable (Simulator).
final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    let service = "app.hearth.keys"
    var authenticationReason = "Unlock protected household records"

    func load(_ key: RootKey) throws -> SymmetricKey {
        switch key {
        case .household:
            guard let data = try read(account: key.rawValue, context: nil) else { throw KeyStoreError.missing(key) }
            return SymmetricKey(data: data)
        case .vault:
            if let wrapped = try read(account: "vault.wrapped", context: nil),
               let seBlob = try read(account: "vault.se-key", context: nil) {
                return try unwrapWithSecureEnclave(wrapped: wrapped, seKeyBlob: seBlob)
            }
            let context = LAContext()
            context.localizedReason = authenticationReason
            guard let data = try read(account: key.rawValue, context: context) else { throw KeyStoreError.missing(key) }
            return SymmetricKey(data: data)
        }
    }

    func store(_ key: SymmetricKey, as root: RootKey) throws {
        let raw = key.withUnsafeBytes { Data($0) }
        switch root {
        case .household:
            try write(raw, account: root.rawValue, accessControl: nil, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        case .vault:
            if SecureEnclave.isAvailable {
                let (wrapped, seBlob) = try wrapWithSecureEnclave(raw)
                try write(seBlob, account: "vault.se-key", accessControl: nil, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
                try write(wrapped, account: "vault.wrapped", accessControl: nil, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
            } else {
                var error: Unmanaged<CFError>?
                guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
                    throw error!.takeRetainedValue() as Error
                }
                try write(raw, account: root.rawValue, accessControl: ac, accessible: nil)
            }
        }
    }

    func exists(_ key: RootKey) -> Bool {
        let accounts = key == .vault ? ["vault.wrapped", key.rawValue] : [key.rawValue]
        return accounts.contains { account in
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
            let status = SecItemCopyMatching(q as CFDictionary, nil)
            return status == errSecSuccess || status == errSecInteractionNotAllowed
        }
    }

    func destroy(_ key: RootKey) throws {
        for account in key == .vault ? ["vault.wrapped", "vault.se-key", key.rawValue] : [key.rawValue] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: account] as CFDictionary)
        }
    }

    // MARK: Secure Enclave wrapping

    private func wrapWithSecureEnclave(_ raw: Data) throws -> (wrapped: Data, seKeyBlob: Data) {
        var error: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                       [.privateKeyUsage, .userPresence], &error) else {
            throw error!.takeRetainedValue() as Error
        }
        let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
        // Wrapping only needs the SE *public* key, so creating the vault needs no prompt.
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let kek = try ephemeral.sharedSecretFromKeyAgreement(with: seKey.publicKey)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("hearth.vault-wrap.v1".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.seal(raw, using: kek).combined!
        var wrapped = Data()
        let eph = ephemeral.publicKey.x963Representation
        wrapped.append(UInt8(eph.count)); wrapped.append(eph); wrapped.append(sealed)
        return (wrapped, seKey.dataRepresentation)
    }

    private func unwrapWithSecureEnclave(wrapped: Data, seKeyBlob: Data) throws -> SymmetricKey {
        let context = LAContext()
        context.localizedReason = authenticationReason
        let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: seKeyBlob, authenticationContext: context)
        let n = Int(wrapped[wrapped.startIndex])
        let ephData = wrapped.subdata(in: (wrapped.startIndex + 1)..<(wrapped.startIndex + 1 + n))
        let sealed = wrapped.subdata(in: (wrapped.startIndex + 1 + n)..<wrapped.endIndex)
        let eph = try P256.KeyAgreement.PublicKey(x963Representation: ephData)
        do {
            let kek = try seKey.sharedSecretFromKeyAgreement(with: eph) // Face ID prompt happens here
                .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("hearth.vault-wrap.v1".utf8), outputByteCount: 32)
            return SymmetricKey(data: try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: kek))
        } catch let e as LAError where e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel {
            throw KeyStoreError.userCancelled
        }
    }

    // MARK: Keychain primitives

    private func read(account: String, context: LAContext?) throws -> Data? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if let context { q[kSecUseAuthenticationContext as String] = context }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess: return out as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled: throw KeyStoreError.userCancelled
        case errSecInteractionNotAllowed: throw KeyStoreError.authenticationRequired(.household)
        default: throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func write(_ data: Data, account: String, accessControl: SecAccessControl?, accessible: CFString?) throws {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: data,
                                kSecAttrSynchronizable as String: false]
        if let accessControl { q[kSecAttrAccessControl as String] = accessControl }
        if let accessible { q[kSecAttrAccessible as String] = accessible }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

/// Connector / AI provider secrets. Never in the database, logs, prompts or exports.
final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    let service = "app.hearth.credentials"

    func secret(for ref: String) throws -> String? {
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: ref, kSecReturnData as String: true]
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func setSecret(_ secret: String, for ref: String) throws {
        try removeSecret(for: ref)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: ref, kSecValueData as String: Data(secret.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                kSecAttrSynchronizable as String: false]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func removeSecret(for ref: String) throws {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: ref] as CFDictionary)
    }
}

/// X25519 key the share extension seals incoming items to. Private half in the Keychain;
/// public half written into the App Group so the extension can read it.
enum InboxKey {
    static let account = "inbox.x25519"
    static var publicKeyURL: URL { AppPaths.groupContainer.appendingPathComponent("inbox-public-key") }

    static func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        let store = KeychainCredentialStore()
        if let b64 = try store.secret(for: account), let raw = Data(base64Encoded: b64) {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try store.setSecret(key.rawRepresentation.base64EncodedString(), for: account)
        try key.publicKey.rawRepresentation.write(to: publicKeyURL, options: .atomic)
        return key
    }
}

enum AppPaths {
    static let appGroup = "group.app.hearth"
    static var groupContainer: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    /// The household store. Lives in the App Group so the share extension can drop into inbox/.
    static var storeRoot: URL { groupContainer.appendingPathComponent("Household", isDirectory: true) }
    static var playbackCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Playback", isDirectory: true)
    }
}
