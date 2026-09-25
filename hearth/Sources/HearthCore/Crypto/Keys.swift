import Crypto
import Foundation

/// Root secrets Hearth needs. None are compiled into the app; all are generated on the
/// household's own devices and kept in a `KeyStore` that is separate from the data.
public enum RootKey: String, CaseIterable, Sendable {
    /// Shared by the household's trusted devices. Seals ordinary records, media and sync bundles.
    case household
    /// Seals `restricted` records (financial, identity, security...). On Apple platforms the
    /// Keychain item is protected by user presence (Face ID / Touch ID / passcode).
    case vault
}

public enum KeyStoreError: Error, Equatable {
    case missing(RootKey)
    /// The platform requires the user to authenticate before this key can be used.
    case authenticationRequired(RootKey)
    case userCancelled
}

/// Where root keys live. Implementations:
/// - `KeychainKeyStore` (Apple app, `Apple/HearthApp/Security`)
/// - `FileKeyStore` (CLI / home server; directory separate from the data directory)
/// - `MemoryKeyStore` (tests)
public protocol KeyStore: AnyObject, Sendable {
    func load(_ key: RootKey) throws -> SymmetricKey
    func store(_ key: SymmetricKey, as root: RootKey) throws
    func exists(_ key: RootKey) -> Bool
    func destroy(_ key: RootKey) throws
}

/// Purpose-specific subkeys derived from the household root with HKDF so that
/// compromise of one derived key does not reveal the others.
public enum KeyPurpose: String, Sendable {
    case records = "hearth.records.v1"
    case media = "hearth.media.v1"
    case mediaNaming = "hearth.media-naming.v1"
    case sync = "hearth.sync.v1"
    case observations = "hearth.observations.v1"
}

public final class KeyRing: @unchecked Sendable {
    private let store: KeyStore
    private let lock = NSLock()
    private var cache: [String: SymmetricKey] = [:]
    private var vaultKey: SymmetricKey?

    public init(store: KeyStore) { self.store = store }

    public func householdRoot() throws -> SymmetricKey { try store.load(.household) }

    public func key(_ purpose: KeyPurpose) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let k = cache[purpose.rawValue] { return k }
        let root = try store.load(.household)
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: root,
                                       info: Data(purpose.rawValue.utf8),
                                       outputByteCount: 32)
        cache[purpose.rawValue] = k
        return k
    }

    // MARK: Vault (restricted records)

    public var isVaultUnlocked: Bool { lock.lock(); defer { lock.unlock() }; return vaultKey != nil }

    /// Loads the vault key. On Apple platforms this triggers biometric / passcode authentication.
    public func unlockVault() throws {
        let k = try store.load(.vault)
        lock.lock(); vaultKey = k; lock.unlock()
    }

    public func lockVault() {
        lock.lock(); vaultKey = nil; lock.unlock()
    }

    public func vault() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        guard let vaultKey else { throw KeyStoreError.authenticationRequired(.vault) }
        return vaultKey
    }

    func key(for keyClass: KeyClass) throws -> SymmetricKey {
        switch keyClass {
        case .household: return try key(.records)
        case .vault: return try vault()
        }
    }

    /// Clears derived keys from memory (e.g. when the app goes to background).
    public func purgeCache() {
        lock.lock(); cache.removeAll(); vaultKey = nil; lock.unlock()
    }

    public static func generateRoots(in store: KeyStore) throws {
        for root in RootKey.allCases where !store.exists(root) {
            try store.store(SymmetricKey(size: .bits256), as: root)
        }
    }
}

/// Which root key seals a record.
public enum KeyClass: String, Codable, Sendable {
    case household
    case vault
}

// MARK: - Key stores

public final class MemoryKeyStore: KeyStore, @unchecked Sendable {
    private var keys: [RootKey: SymmetricKey] = [:]
    private let lock = NSLock()
    public init() {}
    public func load(_ key: RootKey) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        guard let k = keys[key] else { throw KeyStoreError.missing(key) }
        return k
    }
    public func store(_ key: SymmetricKey, as root: RootKey) throws {
        lock.lock(); keys[root] = key; lock.unlock()
    }
    public func exists(_ key: RootKey) -> Bool { lock.lock(); defer { lock.unlock() }; return keys[key] != nil }
    public func destroy(_ key: RootKey) throws { lock.lock(); keys[key] = nil; lock.unlock() }
}

/// Stores keys as 0600 files in a directory that must live apart from the data directory
/// (e.g. `~/.config/hearth/keys` on a home server). Intended for the CLI and servers.
public final class FileKeyStore: KeyStore, @unchecked Sendable {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    private func url(_ key: RootKey) -> URL { directory.appendingPathComponent("\(key.rawValue).key") }
    public func load(_ key: RootKey) throws -> SymmetricKey {
        guard let d = try? Data(contentsOf: url(key)), d.count == 32 else { throw KeyStoreError.missing(key) }
        return SymmetricKey(data: d)
    }
    public func store(_ key: SymmetricKey, as root: RootKey) throws {
        let d = key.withUnsafeBytes { Data($0) }
        try d.write(to: url(root), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(root).path)
    }
    public func exists(_ key: RootKey) -> Bool { FileManager.default.fileExists(atPath: url(key).path) }
    public func destroy(_ key: RootKey) throws {
        if exists(key) { try FileManager.default.removeItem(at: url(key)) }
    }
}
