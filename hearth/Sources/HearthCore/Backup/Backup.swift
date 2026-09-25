import Crypto
import _CryptoExtras
import Foundation

/// A secret the household keeps (printed, in a safe, with a trusted person). Hearth never
/// stores it, so Hearth — or whoever builds it — can never decrypt a backup.
public struct RecoveryKey: Sendable, Equatable {
    public let raw: Data

    public static func generate() -> RecoveryKey {
        var d = Data(count: 20)
        for i in 0..<20 { d[i] = UInt8.random(in: 0...255) }
        return RecoveryKey(raw: d)
    }

    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // 32 symbols, no 0/O/1/I

    /// 32 characters in groups of four, e.g. `K7QW-...`.
    public var displayString: String {
        var bits = 0, value = 0
        var out: [Character] = []
        for byte in raw {
            value = (value << 8) | Int(byte); bits += 8
            while bits >= 5 { out.append(Self.alphabet[(value >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { out.append(Self.alphabet[(value << (5 - bits)) & 31]) }
        return stride(from: 0, to: out.count, by: 4).map { String(out[$0..<min($0 + 4, out.count)]) }.joined(separator: "-")
    }

    public init(raw: Data) { self.raw = raw }

    public init?(displayString: String) {
        var bits = 0, value = 0
        var out = Data()
        for ch in displayString.uppercased() where ch != "-" && ch != " " {
            guard let idx = Self.alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx; bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
        }
        guard out.count == 20 else { return nil }
        raw = out
    }
}

/// Either secret opens a backup.
public enum BackupSecret: Sendable {
    case passphrase(String)
    case recoveryKey(RecoveryKey)
}

struct BackupHeader: Codable {
    struct Wrap: Codable {
        var kind: String          // "passphrase" | "recovery-key"
        var salt: Data
        var scryptLogN: Int
        var sealedBackupKey: Data
    }
    var format = "hearth-backup-v1"
    var backupID: String
    var householdID: String
    var createdAt: Date
    var wraps: [Wrap]
}

struct BackupManifest: Codable {
    struct FileEntry: Codable { var path: String; var sha256: String; var bytes: Int64 }
    var backupID: String
    var createdAt: Date
    var appSchemaVersion: Int
    var recordCounts: [String: Int]
    var opCount: Int
    var mediaSHA256: [String]
    var files: [FileEntry]
}

/// What's inside `keys.sealed`: the household's root keys, so a restore onto a new device
/// (after the old one is lost) can read everything.
struct BackupKeys: Codable {
    var household: Data
    var vault: Data?
    var deviceID: String
    var identityID: String
}

public struct BackupReceipt: Sendable {
    public var backupID: String
    public var location: URL
    public var fileCount: Int
    public var totalBytes: Int64
}

public struct BackupVerification: Sendable, CustomStringConvertible {
    public var ok: Bool
    public var problems: [String]
    public var recordCounts: [String: Int]
    public var mediaChecked: Int
    public var description: String {
        ok ? "OK — \(recordCounts.values.reduce(0, +)) records, \(mediaChecked) media blobs verified"
           : "FAILED — " + problems.joined(separator: "; ")
    }
}

/// Backup = a self-contained directory the household can put anywhere (USB drive, NAS,
/// any cloud). Layout:
///
///     header.json        public: format, salts, the backup key wrapped by each secret
///     manifest.sealed    sealed: file list with SHA-256 of every stored file, counts
///     keys.sealed        sealed: household root keys (so restore works on a new device)
///     database.hblob     sealed SQLite snapshot (values inside are also sealed)
///     media/<id>.hblob   media blobs exactly as stored (already encrypted)
///     README.txt         how to restore, in plain language
public enum BackupManager {
    static let scryptLogN = 17

    public static func createBackup(of store: HearthStore, to parent: URL, passphrase: String,
                                    recoveryKey: RecoveryKey, includeVault: Bool = true) throws -> BackupReceipt {
        let backupID = HearthIDs.new()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dir = parent.appendingPathComponent("Hearth-Backup-\(stamp).hearthbackup")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)

        let backupKey = SymmetricKey(size: .bits256)
        var wraps: [BackupHeader.Wrap] = []
        for (kind, secret) in [("passphrase", Data(passphrase.utf8)), ("recovery-key", recoveryKey.raw)] {
            var salt = Data(count: 16)
            for i in 0..<16 { salt[i] = UInt8.random(in: 0...255) }
            let kek = try KDF.Scrypt.deriveKey(from: secret, salt: salt, outputByteCount: 32, rounds: 1 << scryptLogN, blockSize: 8, parallelism: 1)
            wraps.append(.init(kind: kind, salt: salt, scryptLogN: scryptLogN,
                               sealedBackupKey: try Sealer.seal(backupKey.withUnsafeBytes { Data($0) }, key: kek, aad: Data(backupID.utf8))))
        }
        let header = BackupHeader(backupID: backupID, householdID: store.householdID, createdAt: Date(), wraps: wraps)
        try HearthJSON.prettyEncoder.encode(header).write(to: dir.appendingPathComponent("header.json"))

        var files: [BackupManifest.FileEntry] = []
        func record(_ rel: String) throws {
            let url = dir.appendingPathComponent(rel)
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            files.append(.init(path: rel, sha256: try Hashing.sha256Hex(fileAt: url), bytes: size))
        }

        // Keys
        let keysPayload = BackupKeys(household: try store.keys.householdRoot().withUnsafeBytes { Data($0) },
                                     vault: includeVault ? try? store.keys.vault().withUnsafeBytes { Data($0) } : nil,
                                     deviceID: store.deviceID, identityID: store.identityID)
        try Sealer.sealJSON(keysPayload, key: backupKey, aad: Data("keys".utf8)).write(to: dir.appendingPathComponent("keys.sealed"))
        try record("keys.sealed")

        // Database snapshot
        let snap = fm.temporaryDirectory.appendingPathComponent("hearth-snap-\(backupID).sqlite")
        defer { try? fm.removeItem(at: snap) }
        try store.db.snapshot(to: snap)
        try ChunkedCipher.encrypt(input: snap, output: dir.appendingPathComponent("database.hblob"), key: backupKey)
        try record("database.hblob")

        // Media blobs (already encrypted with the household media key)
        var shas: [String] = []
        for row in try store.db.query("SELECT sha256, blob_id FROM blobs") {
            guard let sha = row.string("sha256"), let blobID = row.string("blob_id") else { continue }
            let src = store.media.blobURL(blobID: blobID)
            guard fm.fileExists(atPath: src.path) else { continue }
            let rel = "media/\(blobID).hblob"
            try fm.copyItem(at: src, to: dir.appendingPathComponent(rel))
            try record(rel)
            shas.append(sha)
        }

        let stats = try store.stats()
        let manifest = BackupManifest(backupID: backupID, createdAt: header.createdAt, appSchemaVersion: Schema.currentVersion,
                                      recordCounts: stats.filter { !$0.key.hasPrefix("_") }, opCount: stats["_ops"] ?? 0,
                                      mediaSHA256: shas.sorted(), files: files)
        try Sealer.sealJSON(manifest, key: backupKey, aad: Data("manifest".utf8)).write(to: dir.appendingPathComponent("manifest.sealed"))
        try readme.write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        DataProtection.protect(dir, level: .media)

        try store.db.execute("INSERT INTO backup_log(backup_id, created_at, location) VALUES (?, ?, ?)",
                             [.text(backupID), .double(header.createdAt.timeIntervalSince1970), .text(dir.path)])
        return BackupReceipt(backupID: backupID, location: dir, fileCount: files.count + 3, totalBytes: files.reduce(0) { $0 + $1.bytes })
    }

    static func unlock(_ dir: URL, secret: BackupSecret) throws -> (BackupHeader, SymmetricKey) {
        let header = try HearthJSON.decoder.decode(BackupHeader.self, from: Data(contentsOf: dir.appendingPathComponent("header.json")))
        let (kind, material): (String, Data)
        switch secret {
        case .passphrase(let p): (kind, material) = ("passphrase", Data(p.utf8))
        case .recoveryKey(let r): (kind, material) = ("recovery-key", r.raw)
        }
        guard let wrap = header.wraps.first(where: { $0.kind == kind }) else { throw SealError.malformed }
        let kek = try KDF.Scrypt.deriveKey(from: material, salt: wrap.salt, outputByteCount: 32, rounds: 1 << wrap.scryptLogN, blockSize: 8, parallelism: 1)
        let raw = try Sealer.open(wrap.sealedBackupKey, key: kek, aad: Data(header.backupID.utf8))
        return (header, SymmetricKey(data: raw))
    }

    /// Verifies every file hash, that the database decrypts and passes integrity check,
    /// and that every media blob decrypts to its recorded SHA-256.
    public static func verify(_ dir: URL, secret: BackupSecret) throws -> BackupVerification {
        var problems: [String] = []
        let (_, key) = try unlock(dir, secret: secret)
        let manifest = try Sealer.openJSON(BackupManifest.self, Data(contentsOf: dir.appendingPathComponent("manifest.sealed")), key: key, aad: Data("manifest".utf8))
        for f in manifest.files {
            let url = dir.appendingPathComponent(f.path)
            guard FileManager.default.fileExists(atPath: url.path) else { problems.append("missing \(f.path)"); continue }
            if try Hashing.sha256Hex(fileAt: url) != f.sha256 { problems.append("checksum mismatch \(f.path)") }
        }
        let keys = try Sealer.openJSON(BackupKeys.self, Data(contentsOf: dir.appendingPathComponent("keys.sealed")), key: key, aad: Data("keys".utf8))
        let mediaKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: keys.household), info: Data(KeyPurpose.media.rawValue.utf8), outputByteCount: 32)
        var mediaChecked = 0
        for f in manifest.files where f.path.hasPrefix("media/") {
            var hasher = SHA256()
            do {
                try ChunkedCipher.decrypt(input: dir.appendingPathComponent(f.path), key: mediaKey) { hasher.update(data: $0) }
                let sha = hasher.finalize().hexString
                if !manifest.mediaSHA256.contains(sha) { problems.append("media \(f.path) content does not match any recorded hash") }
                mediaChecked += 1
            } catch {
                problems.append("media \(f.path) does not decrypt")
            }
        }
        let snap = FileManager.default.temporaryDirectory.appendingPathComponent("verify-\(HearthIDs.new()).sqlite")
        defer { try? FileManager.default.removeItem(at: snap) }
        do {
            try ChunkedCipher.decrypt(input: dir.appendingPathComponent("database.hblob"), output: snap, key: key)
            let db = try SQLiteDatabase(path: snap.path)
            if try !db.integrityCheck() { problems.append("database integrity check failed") }
            let ops = Int(try db.query("SELECT COUNT(*) AS n FROM ops").first?.int("n") ?? -1)
            if ops != manifest.opCount { problems.append("op count \(ops) != manifest \(manifest.opCount)") }
            db.close()
        } catch {
            problems.append("database: \(error)")
        }
        return BackupVerification(ok: problems.isEmpty, problems: problems, recordCounts: manifest.recordCounts, mediaChecked: mediaChecked)
    }

    /// Restores into `root` (must not already contain a store) and writes the recovered root
    /// keys into `keyStore`.
    @discardableResult
    public static func restore(_ dir: URL, secret: BackupSecret, into root: URL, keyStore: KeyStore) throws -> HearthStore {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent(HearthStore.databaseName).path) else {
            throw HearthStoreError.invalid("restore target already contains a Hearth store")
        }
        let (_, key) = try unlock(dir, secret: secret)
        let keys = try Sealer.openJSON(BackupKeys.self, Data(contentsOf: dir.appendingPathComponent("keys.sealed")), key: key, aad: Data("keys".utf8))
        try keyStore.store(SymmetricKey(data: keys.household), as: .household)
        if let v = keys.vault { try keyStore.store(SymmetricKey(data: v), as: .vault) }
        try HearthStore.prepareDirectories(root)
        try ChunkedCipher.decrypt(input: dir.appendingPathComponent("database.hblob"),
                                  output: root.appendingPathComponent(HearthStore.databaseName), key: key)
        let store = try HearthStore.open(at: root, keyStore: keyStore)
        let mediaDir = dir.appendingPathComponent("media")
        for file in (try? fm.contentsOfDirectory(atPath: mediaDir.path)) ?? [] where file.hasSuffix(".hblob") {
            let blobID = String(file.dropLast(6))
            let dest = store.media.blobURL(blobID: blobID)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: mediaDir.appendingPathComponent(file), to: dest) }
        }
        return store
    }

    public struct TestRestoreResult: Sendable, CustomStringConvertible {
        public var ok: Bool
        public var problems: [String]
        public var restoredCounts: [String: Int]
        public var description: String {
            ok ? "TEST RESTORE PASSED — \(restoredCounts.filter { !$0.key.hasPrefix("_") }.values.reduce(0, +)) records, \(restoredCounts["_blobs"] ?? 0) media blobs, all media verified"
               : "TEST RESTORE FAILED — " + problems.joined(separator: "; ")
        }
    }

    /// Restores into a throwaway location with a throwaway key store, checks that every
    /// record decrypts and every media blob verifies, then deletes the copy. Only a backup
    /// that passes this is marked verified.
    public static func testRestore(_ dir: URL, secret: BackupSecret, recordingIn store: HearthStore? = nil) throws -> TestRestoreResult {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-test-restore-\(HearthIDs.new())")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var problems: [String] = []
        let verification = try verify(dir, secret: secret)
        problems += verification.problems
        let (header, _) = try unlock(dir, secret: secret)
        let restored = try restore(dir, secret: secret, into: tmp, keyStore: MemoryKeyStore())
        defer { restored.close() }
        if (try? restored.keys.unlockVault()) != nil { try restored.materializePending() }
        let counts = try restored.stats()
        for (kind, n) in verification.recordCounts where counts[kind] != n {
            problems.append("\(kind): restored \(counts[kind] ?? 0), expected \(n)")
        }
        let envs = try restored.allEnvelopes(kind: nil, includeDeleted: true, enforcePermissions: false)
        if envs.count < verification.recordCounts.values.reduce(0, +) { problems.append("some records failed to decrypt") }
        let integrity = try restored.media.verifyAll()
        if !integrity.ok { problems.append("media missing \(integrity.missing.count), corrupt \(integrity.corrupt.count)") }

        let ok = problems.isEmpty
        if ok, let store {
            let now = Date().timeIntervalSince1970
            try store.db.execute("""
                INSERT INTO backup_log(backup_id, created_at, location, verified_at, test_restored_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(backup_id) DO UPDATE SET verified_at = excluded.verified_at, test_restored_at = excluded.test_restored_at
                """, [.text(header.backupID), .double(header.createdAt.timeIntervalSince1970), .text(dir.path), .double(now), .double(now)])
        }
        return TestRestoreResult(ok: ok, problems: problems, restoredCounts: counts)
    }

    public struct BackupLogEntry: Sendable {
        public var id: String
        public var createdAt: Date
        public var location: String
        public var verifiedByTestRestore: Date?
    }

    public static func log(_ store: HearthStore) throws -> [BackupLogEntry] {
        try store.db.query("SELECT * FROM backup_log ORDER BY created_at DESC").map {
            BackupLogEntry(id: $0.string("backup_id") ?? "", createdAt: Date(timeIntervalSince1970: $0.double("created_at") ?? 0),
                           location: $0.string("location") ?? "",
                           verifiedByTestRestore: $0.double("test_restored_at").map(Date.init(timeIntervalSince1970:)))
        }
    }

    static let readme = """
    HEARTH BACKUP
    =============

    This folder is a complete, encrypted backup of a Hearth household: every record,
    its full history, photos, videos, audio, documents, procedures, permissions and
    configuration.

    It can be opened with EITHER:
      • the backup passphrase, or
      • the recovery key (32 characters, XXXX-XXXX-...) shown when the backup was made.

    Nobody else has these — not the makers of Hearth, not Apple, not a cloud provider.
    If both are lost, this backup cannot be opened by anyone.

    To restore:
      • iPhone/iPad/Mac: Hearth → Settings → Backup → Restore from backup…
      • Any computer:    hearthctl restore <this folder> <new-directory> --recovery-key XXXX-...

    Format (open, documented in docs/ARCHITECTURE.md of the Hearth source):
      header.json      scrypt salts and the backup key wrapped by each secret (AES-256-GCM)
      manifest.sealed  list of files with SHA-256 checksums
      keys.sealed      the household's encryption keys
      database.hblob   SQLite database snapshot (chunked AES-256-GCM)
      media/*.hblob    encrypted media, verified against SHA-256 of the originals
    """
}
