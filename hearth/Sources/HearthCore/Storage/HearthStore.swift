import Crypto
import Foundation

public enum HearthStoreError: Error, Equatable {
    case notAHearthStore(String)
    case recordNotFound(String)
    case invalid(String)
    case vaultLocked
}

/// The sovereign local store: an encrypted SQLite database plus an encrypted,
/// content-addressed media directory, both owned by the household.
///
/// Layout of `root`:
///
///     hearth.sqlite      operation log + materialized state (values sealed with AES-GCM)
///     media/             encrypted content-addressed blobs
///     inbox/             drop zone for the share extension / imports
///
/// Keys are *not* stored under `root`; they come from the `KeyStore`.
public final class HearthStore: @unchecked Sendable {
    public let root: URL
    public let db: SQLiteDatabase
    public let keys: KeyRing
    public let clock: HybridClock
    public let deviceID: String
    public let householdID: String
    public private(set) var identityID: String
    let index = SearchIndex()

    public lazy var media = MediaStore(store: self)
    public lazy var live = LiveDataService(store: self)

    public static let databaseName = "hearth.sqlite"

    // MARK: Lifecycle

    /// Creates a brand-new household on this device. No server, account or network is involved.
    public static func createHousehold(at root: URL, keyStore: KeyStore, householdName: String,
                                       ownerName: String, deviceName: String, platform: String) throws -> HearthStore {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent(databaseName).path) {
            throw HearthStoreError.invalid("a Hearth store already exists at \(root.path)")
        }
        try KeyRing.generateRoots(in: keyStore)
        try prepareDirectories(root)
        let db = try SQLiteDatabase(path: root.appendingPathComponent(databaseName).path)
        try Schema.migrate(db)
        let deviceID = HearthIDs.new()
        let household = Household(name: householdName)
        let owner = Identity(displayName: ownerName, role: .owner)
        try setMeta(db, "device_id", deviceID)
        try setMeta(db, "household_id", household.id)
        try setMeta(db, "identity_id", owner.id)
        try setMeta(db, "format", "hearth-store-v1")
        db.close()

        let store = try open(at: root, keyStore: keyStore)
        try store.save(household, provenance: .system)
        try store.save(owner, provenance: .system)
        try store.save(DeviceRecord(id: deviceID, name: deviceName, platform: platform, ownerIdentity: owner.id), provenance: .system)
        return store
    }

    /// Joins an existing household on a new device using an enrollment package from a trusted
    /// device. The household's data arrives through whatever sync transport the family uses.
    public static func joinHousehold(at root: URL, keyStore: KeyStore, enrollment: Enrollment) throws -> HearthStore {
        try keyStore.store(SymmetricKey(data: enrollment.householdKey), as: .household)
        if let vault = enrollment.vaultKey { try keyStore.store(SymmetricKey(data: vault), as: .vault) }
        try prepareDirectories(root)
        let db = try SQLiteDatabase(path: root.appendingPathComponent(databaseName).path)
        try Schema.migrate(db)
        try setMeta(db, "device_id", enrollment.device.id)
        try setMeta(db, "household_id", enrollment.householdID)
        try setMeta(db, "identity_id", enrollment.device.ownerIdentity)
        try setMeta(db, "format", "hearth-store-v1")
        db.close()
        let store = try open(at: root, keyStore: keyStore)
        _ = try store.applyBatch(enrollment.bootstrapOps)
        return store
    }

    public static func open(at root: URL, keyStore: KeyStore) throws -> HearthStore {
        let dbURL = root.appendingPathComponent(databaseName)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw HearthStoreError.notAHearthStore(root.path)
        }
        let db = try SQLiteDatabase(path: dbURL.path)
        try Schema.migrate(db)
        return try HearthStore(root: root, db: db, keyStore: keyStore)
    }

    private init(root: URL, db: SQLiteDatabase, keyStore: KeyStore) throws {
        self.root = root
        self.db = db
        self.keys = KeyRing(store: keyStore)
        guard let device = try Self.meta(db, "device_id"),
              let household = try Self.meta(db, "household_id"),
              let identity = try Self.meta(db, "identity_id") else {
            throw HearthStoreError.notAHearthStore(root.path)
        }
        deviceID = device
        householdID = household
        identityID = identity
        let lastHLC = try db.query("SELECT MAX(hlc) AS h FROM ops").first?.string("h").flatMap(HLC.init) ?? .zero
        clock = HybridClock(node: device, last: lastHLC)
        _ = try keys.key(.records) // fail fast if the household key is unavailable
        try rebuildSearchIndex()
    }

    static func prepareDirectories(_ root: URL) throws {
        let fm = FileManager.default
        for dir in [root, root.appendingPathComponent("media"), root.appendingPathComponent("inbox")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        DataProtection.protect(root, level: .database)
        DataProtection.protect(root.appendingPathComponent("media"), level: .media)
    }

    public func close() { db.close(); keys.purgeCache() }

    // MARK: Meta

    static func setMeta(_ db: SQLiteDatabase, _ key: String, _ value: String) throws {
        try db.execute("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
    }

    static func meta(_ db: SQLiteDatabase, _ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.string("value")
    }

    public func setMeta(_ key: String, _ value: String) throws { try Self.setMeta(db, key, value) }
    public func meta(_ key: String) throws -> String? { try Self.meta(db, key) }

    // MARK: Identity

    public func currentIdentity() throws -> Identity {
        guard let env = try envelope(identityID), let identity = try? env.decode(Identity.self) else {
            // Before the first sync on a joined device, act with least privilege.
            return Identity(id: identityID, displayName: "Unknown", role: .guest)
        }
        return identity
    }

    /// Switch which family member is using this device (e.g. a shared family iPad).
    public func switchIdentity(to id: String) throws {
        identityID = id
        try setMeta("identity_id", id)
    }

    // MARK: Vault

    public func unlockVault() throws {
        try keys.unlockVault()
        try materializePending()
        for env in try allEnvelopes(kind: nil, includeDeleted: false) where env.keyClass == .vault {
            index.index(env)
        }
    }

    public func lockVault() {
        keys.lockVault()
        index.dropVaultRecords()
    }

    // MARK: Writing

    /// Saves a record. Only fields that changed produce a new operation, and the previous
    /// values stay in the history.
    @discardableResult
    public func save<R: HearthRecord>(_ record: R, provenance: Provenance = .manual) throws -> Operation? {
        var fields = try JSONValue.fields(of: record)
        let minimum = SensitivityPolicy.minimumSensitivity(for: record.categories)
        if record.sensitivity < minimum { fields["sensitivity"] = .string(minimum.rawValue) }
        let sensitivity = fields["sensitivity"]?.stringValue.flatMap(Sensitivity.init) ?? .normal
        if record.emergency && sensitivity == .restricted {
            throw HearthStoreError.invalid("Emergency records must stay readable without the vault; lower sensitivity to private.")
        }
        // Clear only fields this version of the type knows about (a known optional set to nil).
        // Fields written by newer app versions are preserved untouched.
        if let existing = try envelope(record.id), let oldTyped = try? existing.decode(R.self) {
            for key in try JSONValue.fields(of: oldTyped).keys where fields[key] == nil { fields[key] = .null }
        }
        return try write(kind: R.kind, id: record.id, fields: fields, provenance: provenance, replace: false)
    }

    @discardableResult
    func write(kind: RecordKind, id: String, fields: [String: JSONValue], provenance: Provenance, replace: Bool = true) throws -> Operation? {
        try db.transaction {
            let existing = try envelope(id)
            if provenance.method != .system {
                let identity = try currentIdentity()
                let prospective = existing ?? RecordEnvelope(id: id, kind: kind, fields: fields, keyClass: .household, createdAt: .zero, updatedAt: .zero)
                guard AccessPolicy.canWrite(identity, prospective) else {
                    throw AccessError.notPermitted("\(identity.displayName) cannot modify \(kind.rawValue) \(id)")
                }
            }
            var changed: [String: JSONValue] = [:]
            let old = existing?.fields ?? [:]
            for (k, v) in fields where old[k] ?? .null != v { changed[k] = v }
            if replace {
                for (k, v) in old where fields[k] == nil && v != .null { changed[k] = .null }
            }
            guard !changed.isEmpty else { return nil }

            let merged = old.merging(changed) { $1 }
            let sensitivity = merged["sensitivity"]?.stringValue.flatMap(Sensitivity.init) ?? .normal
            let keyClass: KeyClass = sensitivity == .restricted ? .vault : .household
            if keyClass == .vault && !keys.isVaultUnlocked { throw HearthStoreError.vaultLocked }

            var parents: [String: String] = [:]
            for f in changed.keys {
                if let head = try db.query("SELECT op_id FROM field_heads WHERE record_id = ? AND field = ?", [.text(id), .text(f)]).first?.string("op_id") {
                    parents[f] = head
                }
            }
            let opID = HearthIDs.new()
            let op = Operation(id: opID, hlc: clock.now(), actor: identityID, device: deviceID,
                               recordKind: kind, recordID: id, action: .upsert,
                               fieldNames: changed.keys.sorted(), parents: parents, keyClass: keyClass,
                               sealedValues: try Sealer.sealJSON(changed, key: keys.key(for: keyClass), aad: Data(opID.utf8)),
                               provenance: provenance)
            _ = try apply(op, source: .local)
            if existing?.keyClass == .household && keyClass == .vault {
                try resealHistory(recordID: id, to: .vault)
            }
            return op
        }
    }

    /// Partial update of specific fields (other fields, including ones this app version does
    /// not know, are untouched).
    @discardableResult
    public func update(_ id: String, fields: [String: JSONValue], provenance: Provenance = .manual) throws -> Operation? {
        guard let env = try envelope(id) else { throw HearthStoreError.recordNotFound(id) }
        return try write(kind: env.kind, id: id, fields: fields, provenance: provenance, replace: false)
    }

    /// Soft delete: the record disappears from normal views but its history remains.
    public func delete(_ id: String, provenance: Provenance = .manual) throws {
        guard let env = try envelope(id) else { throw HearthStoreError.recordNotFound(id) }
        try write(kind: env.kind, id: id, fields: ["deleted": .bool(true)], provenance: provenance, replace: false)
    }

    // MARK: Applying operations

    public enum ApplySource: Sendable { case local, sync, restore }

    public enum ApplyResult: Equatable, Sendable {
        case applied
        case duplicate
        case deferredUntilVaultUnlocked
        case rejected(String)
    }

    /// Idempotently applies an operation (local or from another device).
    public func apply(_ op: Operation, source: ApplySource) throws -> ApplyResult {
        try db.transaction {
            if try !db.query("SELECT 1 FROM ops WHERE op_id = ?", [.text(op.id)]).isEmpty { return .duplicate }
            if source == .sync {
                clock.observe(op.hlc)
                if let reason = try rejectionReason(op) { return .rejected(reason) }
            }
            try db.execute("""
                INSERT INTO ops(op_id, hlc, actor, device, record_kind, record_id, action, field_names, parents,
                                key_class, sealed_values, provenance, received_hlc, materialized)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                """, [.text(op.id), .text(op.hlc.description), .text(op.actor), .text(op.device),
                      .text(op.recordKind.rawValue), .text(op.recordID), .text(op.action.rawValue),
                      .text(String(decoding: try HearthJSON.encoder.encode(op.fieldNames), as: UTF8.self)),
                      .text(String(decoding: try HearthJSON.encoder.encode(op.parents), as: UTF8.self)),
                      .text(op.keyClass.rawValue), .blob(op.sealedValues),
                      .text(String(decoding: try HearthJSON.encoder.encode(op.provenance), as: UTF8.self)),
                      .text(clock.now().description)])
            return try materialize(op) ? .applied : .deferredUntilVaultUnlocked
        }
    }

    /// Applies a batch from another device: device records first (so authorship can be
    /// verified), then everything else in causal order.
    public func applyBatch(_ ops: [Operation]) throws -> [ApplyResult] {
        let ordered = ops.filter { $0.recordKind == .device }.sorted { $0.hlc < $1.hlc }
            + ops.filter { $0.recordKind != .device }.sorted { $0.hlc < $1.hlc }
        return try ordered.map { try apply($0, source: .sync) }
    }

    private func rejectionReason(_ op: Operation) throws -> String? {
        guard let devEnv = try envelope(op.device), let dev = try? devEnv.decode(DeviceRecord.self) else {
            // Unknown device: accept only its own enrollment record, created by a trusted device.
            return op.recordKind == .device ? nil : "operation from unknown device \(op.device)"
        }
        if let revoked = dev.revokedAt, op.hlc > revoked {
            return "device \(dev.name) was revoked at \(revoked)"
        }
        return nil
    }

    /// Merges an op into current state. Returns false if the needed key is locked.
    @discardableResult
    private func materialize(_ op: Operation) throws -> Bool {
        if op.action == .purge {
            try executePurge(recordID: op.recordID, purgeOp: op.id)
            try db.execute("UPDATE ops SET materialized = 1 WHERE op_id = ?", [.text(op.id)])
            return true
        }
        let existingRow = try db.query("SELECT * FROM records WHERE record_id = ?", [.text(op.recordID)]).first
        let existingClass = existingRow?.string("key_class").flatMap(KeyClass.init) ?? .household
        guard canUse(op.keyClass), canUse(existingClass) else { return false }

        let values = try Sealer.openJSON([String: JSONValue].self, op.sealedValues,
                                         key: keys.key(for: op.keyClass), aad: Data(op.id.utf8))
        var fields: [String: JSONValue] = [:]
        if let existingRow, let sealed = existingRow.data("sealed_fields") {
            fields = try Sealer.openJSON([String: JSONValue].self, sealed, key: keys.key(for: existingClass), aad: Data(op.recordID.utf8))
        }

        for f in op.fieldNames {
            let head = try db.query("SELECT op_id, hlc FROM field_heads WHERE record_id = ? AND field = ?",
                                    [.text(op.recordID), .text(f)]).first
            guard let head, let headOp = head.string("op_id"), let headHLC = head.string("hlc").flatMap(HLC.init) else {
                try setHead(op, field: f)
                fields[f] = values[f] ?? .null
                continue
            }
            if headOp == op.id { continue }
            if op.hlc > headHLC {
                if try !isAncestor(headOp, of: op.id, field: f, parents: op.parents) {
                    try recordConflict(recordID: op.recordID, field: f, winner: op.id, loser: headOp)
                }
                try setHead(op, field: f)
                fields[f] = values[f] ?? .null
            } else if try !isAncestor(op.id, of: headOp, field: f, parents: nil) {
                try recordConflict(recordID: op.recordID, field: f, winner: headOp, loser: op.id)
            }
        }

        let sensitivity = fields["sensitivity"]?.stringValue.flatMap(Sensitivity.init) ?? .normal
        let keyClass: KeyClass = sensitivity == .restricted ? .vault : .household
        guard canUse(keyClass) else { return false }
        let sealed = try Sealer.sealJSON(fields, key: keys.key(for: keyClass), aad: Data(op.recordID.utf8))
        let created = existingRow?.string("created_hlc") ?? op.hlc.description
        let updatedHLC = max(existingRow?.string("updated_hlc").flatMap(HLC.init) ?? .zero, op.hlc)
        try db.execute("""
            INSERT INTO records(record_id, kind, key_class, sealed_fields, sensitivity, emergency, deleted, created_hlc, updated_hlc)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(record_id) DO UPDATE SET key_class = excluded.key_class, sealed_fields = excluded.sealed_fields,
                sensitivity = excluded.sensitivity, emergency = excluded.emergency, deleted = excluded.deleted,
                updated_hlc = excluded.updated_hlc
            """, [.text(op.recordID), .text(op.recordKind.rawValue), .text(keyClass.rawValue), .blob(sealed),
                  .text(sensitivity.rawValue), .bool(fields["emergency"]?.boolValue ?? false),
                  .bool(fields["deleted"]?.boolValue ?? false), .text(created), .text(updatedHLC.description)])
        try db.execute("UPDATE ops SET materialized = 1 WHERE op_id = ?", [.text(op.id)])
        index.index(RecordEnvelope(id: op.recordID, kind: op.recordKind, fields: fields, keyClass: keyClass,
                                   createdAt: HLC(created) ?? op.hlc, updatedAt: updatedHLC))
        return true
    }

    private func canUse(_ keyClass: KeyClass) -> Bool { keyClass == .household || keys.isVaultUnlocked }

    private func setHead(_ op: Operation, field: String) throws {
        try db.execute("""
            INSERT INTO field_heads(record_id, field, op_id, hlc) VALUES (?, ?, ?, ?)
            ON CONFLICT(record_id, field) DO UPDATE SET op_id = excluded.op_id, hlc = excluded.hlc
            """, [.text(op.recordID), .text(field), .text(op.id), .text(op.hlc.description)])
    }

    /// True if `ancestor` is in the per-field parent chain of `descendant`.
    private func isAncestor(_ ancestor: String, of descendant: String, field: String, parents: [String: String]?) throws -> Bool {
        var current: String? = try parents?[field] ?? parentsOf(descendant)[field]
        var steps = 0
        while let c = current, steps < 100_000 {
            if c == ancestor { return true }
            current = try parentsOf(c)[field]
            steps += 1
        }
        return false
    }

    private func parentsOf(_ opID: String) throws -> [String: String] {
        guard let json = try db.query("SELECT parents FROM ops WHERE op_id = ?", [.text(opID)]).first?.string("parents") else { return [:] }
        return (try? HearthJSON.decoder.decode([String: String].self, from: Data(json.utf8))) ?? [:]
    }

    private func recordConflict(recordID: String, field: String, winner: String, loser: String) throws {
        let exists = try db.query("SELECT 1 FROM conflicts WHERE record_id = ? AND field = ? AND ((winning_op = ? AND losing_op = ?) OR (winning_op = ? AND losing_op = ?))",
                                  [.text(recordID), .text(field), .text(winner), .text(loser), .text(loser), .text(winner)])
        guard exists.isEmpty else { return }
        try db.execute("INSERT INTO conflicts(conflict_id, record_id, field, winning_op, losing_op, detected_hlc) VALUES (?, ?, ?, ?, ?, ?)",
                       [.text(HearthIDs.new()), .text(recordID), .text(field), .text(winner), .text(loser), .text(clock.now().description)])
    }

    /// Materializes ops that arrived while the vault was locked.
    public func materializePending() throws {
        let rows = try db.query("SELECT * FROM ops WHERE materialized = 0 ORDER BY hlc")
        for row in rows {
            let op = try Self.operation(from: row)
            _ = try db.transaction { try materialize(op) }
        }
    }

    private func resealHistory(recordID: String, to keyClass: KeyClass) throws {
        for row in try db.query("SELECT op_id, key_class, sealed_values FROM ops WHERE record_id = ? AND redacted = 0", [.text(recordID)]) {
            guard let opID = row.string("op_id"), let from = row.string("key_class").flatMap(KeyClass.init),
                  from != keyClass, let sealed = row.data("sealed_values") else { continue }
            let plain = try Sealer.open(sealed, key: keys.key(for: from), aad: Data(opID.utf8))
            let resealed = try Sealer.seal(plain, key: keys.key(for: keyClass), aad: Data(opID.utf8))
            try db.execute("UPDATE ops SET key_class = ?, sealed_values = ? WHERE op_id = ?", [.text(keyClass.rawValue), .blob(resealed), .text(opID)])
        }
    }

    // MARK: Reading

    public func envelope(_ id: String) throws -> RecordEnvelope? {
        guard let row = try db.query("SELECT * FROM records WHERE record_id = ?", [.text(id)]).first else { return nil }
        return try envelope(from: row)
    }

    func envelope(from row: SQLRow) throws -> RecordEnvelope {
        guard let id = row.string("record_id"), let kind = row.string("kind"),
              let keyClass = row.string("key_class").flatMap(KeyClass.init),
              let sealed = row.data("sealed_fields") else { throw HearthStoreError.invalid("corrupt record row") }
        guard canUse(keyClass) else { throw HearthStoreError.vaultLocked }
        let fields = try Sealer.openJSON([String: JSONValue].self, sealed, key: keys.key(for: keyClass), aad: Data(id.utf8))
        return RecordEnvelope(id: id, kind: RecordKind(rawValue: kind), fields: fields, keyClass: keyClass,
                              createdAt: row.string("created_hlc").flatMap(HLC.init) ?? .zero,
                              updatedAt: row.string("updated_hlc").flatMap(HLC.init) ?? .zero)
    }

    /// All records of a kind readable by the current identity. Vault records are skipped
    /// while the vault is locked (see `lockedCount`).
    public func allEnvelopes(kind: RecordKind?, includeDeleted: Bool = false, enforcePermissions: Bool = true) throws -> [RecordEnvelope] {
        var sql = "SELECT * FROM records WHERE 1 = 1"
        var params: [SQLValue] = []
        if let kind { sql += " AND kind = ?"; params.append(.text(kind.rawValue)) }
        if !includeDeleted { sql += " AND deleted = 0" }
        if !keys.isVaultUnlocked { sql += " AND key_class = 'household'" }
        sql += " ORDER BY updated_hlc DESC"
        let identity = try currentIdentity()
        return try db.query(sql, params).map(envelope(from:)).filter { !enforcePermissions || AccessPolicy.canRead(identity, $0) }
    }

    public func lockedCount(kind: RecordKind? = nil) throws -> Int {
        guard !keys.isVaultUnlocked else { return 0 }
        var sql = "SELECT COUNT(*) AS n FROM records WHERE key_class = 'vault' AND deleted = 0"
        var params: [SQLValue] = []
        if let kind { sql += " AND kind = ?"; params.append(.text(kind.rawValue)) }
        return Int(try db.query(sql, params).first?.int("n") ?? 0)
    }

    public func fetch<R: HearthRecord>(_ type: R.Type, id: String) throws -> R? {
        guard let env = try envelope(id), env.kind == R.kind else { return nil }
        guard AccessPolicy.canRead(try currentIdentity(), env) else { throw AccessError.notPermitted(id) }
        return try env.decode(type)
    }

    public func all<R: HearthRecord>(_ type: R.Type, includeDeleted: Bool = false) throws -> [R] {
        try allEnvelopes(kind: R.kind, includeDeleted: includeDeleted).compactMap { try? $0.decode(type) }
    }

    public func relationships(of id: String) throws -> [Relationship] {
        try all(Relationship.self).filter { $0.from == id || $0.to == id }
    }

    @discardableResult
    public func link(_ from: String, to: String, type: String, provenance: Provenance = .manual) throws -> Relationship {
        if let existing = try relationships(of: from).first(where: { $0.from == from && $0.to == to && $0.type == type }) {
            return existing
        }
        let rel = Relationship(from: from, to: to, type: type)
        try save(rel, provenance: provenance)
        return rel
    }

    public func emergencyRecords() throws -> [RecordEnvelope] {
        let identity = try currentIdentity()
        return try db.query("SELECT * FROM records WHERE emergency = 1 AND deleted = 0 AND key_class = 'household'")
            .map(envelope(from:))
            .filter { AccessPolicy.canRead(identity, $0) || identity.role == .emergencyAccess }
    }

    /// Maintenance and reminders with a due date inside the window and not yet completed.
    public func dueEvents(within interval: TimeInterval, now: Date = Date()) throws -> [HouseholdEvent] {
        try all(HouseholdEvent.self)
            .filter { $0.completedAt == nil && ($0.dueAt.map { $0 <= now.addingTimeInterval(interval) } ?? false) }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
    }

    // MARK: Search

    public struct SearchHit: Sendable {
        public var record: RecordEnvelope
        public var score: Int
    }

    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let identity = try currentIdentity()
        return try index.search(query)
            .sorted { $0.value > $1.value }
            .compactMap { id, score -> SearchHit? in
                guard let env = try? envelope(id), !env.deleted, AccessPolicy.canRead(identity, env) else { return nil }
                return SearchHit(record: env, score: score)
            }
            .prefix(limit)
            .map { $0 }
    }

    func rebuildSearchIndex() throws {
        index.clear()
        for env in try allEnvelopes(kind: nil, includeDeleted: false, enforcePermissions: false) { index.index(env) }
    }

    // MARK: History & conflicts

    public func history(of recordID: String) throws -> [HistoryEntry] {
        try db.query("SELECT * FROM ops WHERE record_id = ? ORDER BY hlc", [.text(recordID)]).map { row in
            let op = try Self.operation(from: row)
            let redacted = row.bool("redacted")
            var values: [String: JSONValue]?
            if !redacted, canUse(op.keyClass) {
                values = try? Sealer.openJSON([String: JSONValue].self, op.sealedValues, key: keys.key(for: op.keyClass), aad: Data(op.id.utf8))
            }
            return HistoryEntry(opID: op.id, at: op.hlc, actor: op.actor, device: op.device, action: op.action,
                                values: values, provenance: op.provenance, redacted: redacted)
        }
    }

    public func conflicts(includeResolved: Bool = false) throws -> [Conflict] {
        let rows = try db.query("SELECT * FROM conflicts" + (includeResolved ? "" : " WHERE resolved_op IS NULL") + " ORDER BY detected_hlc")
        return try rows.map { row in
            let winner = row.string("winning_op") ?? "", loser = row.string("losing_op") ?? ""
            let field = row.string("field") ?? ""
            return Conflict(id: row.string("conflict_id") ?? "", recordID: row.string("record_id") ?? "", field: field,
                            winningOp: winner, losingOp: loser,
                            winningValue: try value(of: winner, field: field), losingValue: try value(of: loser, field: field),
                            winningDevice: try deviceOf(winner), losingDevice: try deviceOf(loser),
                            detectedAt: row.string("detected_hlc").flatMap(HLC.init) ?? .zero)
        }
    }

    private func deviceOf(_ opID: String) throws -> String? {
        try db.query("SELECT device FROM ops WHERE op_id = ?", [.text(opID)]).first?.string("device")
    }

    private func value(of opID: String, field: String) throws -> JSONValue? {
        guard let row = try db.query("SELECT * FROM ops WHERE op_id = ?", [.text(opID)]).first else { return nil }
        let op = try Self.operation(from: row)
        guard canUse(op.keyClass), !row.bool("redacted") else { return nil }
        let values = try Sealer.openJSON([String: JSONValue].self, op.sealedValues, key: keys.key(for: op.keyClass), aad: Data(op.id.utf8))
        return values[field]
    }

    public enum Resolution: Sendable { case keepWinner, takeLoser, custom(JSONValue) }

    /// Resolves a conflict with a new operation; both original values remain in history.
    public func resolve(_ conflict: Conflict, with resolution: Resolution) throws {
        guard let env = try envelope(conflict.recordID) else { throw HearthStoreError.recordNotFound(conflict.recordID) }
        let value: JSONValue
        switch resolution {
        case .keepWinner: value = conflict.winningValue ?? .null
        case .takeLoser: value = conflict.losingValue ?? .null
        case .custom(let v): value = v
        }
        let op = try write(kind: env.kind, id: env.id, fields: [conflict.field: value],
                           provenance: Provenance(.conflictResolution, source: conflict.id), replace: false)
        try db.execute("UPDATE conflicts SET resolved_op = ? WHERE conflict_id = ?", [.text(op?.id ?? "no-change"), .text(conflict.id)])
    }

    // MARK: Deletion means deletion

    public struct DeletionReport: Sendable {
        public var recordIDs: [String]
        public var mediaBlobsRemoved: Int
        public var historyEntriesRedacted: Int
        public var willPropagateToSyncReplicas: Bool
        public var backupsThatMayStillContainData: [(id: String, createdAt: Date, location: String)]
        public var explanation: String
    }

    /// Permanently deletes a record: current state, all historical values, search index,
    /// media blobs and derivatives (for media), and emits a content-free purge operation so
    /// other household devices delete their copies on next sync.
    @discardableResult
    public func purge(_ id: String) throws -> DeletionReport {
        guard let env = try envelope(id) else { throw HearthStoreError.recordNotFound(id) }
        guard AccessPolicy.canWrite(try currentIdentity(), env) else { throw AccessError.notPermitted(id) }
        var targets = [id]
        if env.kind == .media {
            targets += try all(MediaObject.self, includeDeleted: true).filter { $0.derivedFrom == id }.map(\.id)
        }
        targets += try all(Relationship.self, includeDeleted: true).filter { targets.contains($0.from) || targets.contains($0.to) }.map(\.id)
        var redacted = 0, blobs = 0
        for target in targets {
            redacted += Int(try db.query("SELECT COUNT(*) AS n FROM ops WHERE record_id = ? AND redacted = 0", [.text(target)]).first?.int("n") ?? 0)
            blobs += try media.removeBlobIfUnreferenced(forRecord: target, excluding: Set(targets))
            let op = Operation(id: HearthIDs.new(), hlc: clock.now(), actor: identityID, device: deviceID,
                               recordKind: (try envelope(target))?.kind ?? env.kind, recordID: target, action: .purge,
                               fieldNames: [], parents: [:], keyClass: .household, sealedValues: Data(),
                               provenance: .manual)
            _ = try apply(op, source: .local)
        }
        let backups = try db.query("SELECT backup_id, created_at, location FROM backup_log ORDER BY created_at").map {
            (id: $0.string("backup_id") ?? "", createdAt: Date(timeIntervalSince1970: $0.double("created_at") ?? 0), location: $0.string("location") ?? "")
        }
        var explanation = "Removed from this device: current record, every historical value, search index"
        explanation += env.kind == .media ? ", the encrypted original, and all derivatives (thumbnails, transcripts, AI analysis)." : "."
        explanation += " A content-free purge instruction will be sent to other household devices on their next sync."
        if !backups.isEmpty {
            explanation += " \(backups.count) backup(s) made before now may still contain this data until they are deleted or rotated."
        }
        return DeletionReport(recordIDs: targets, mediaBlobsRemoved: blobs, historyEntriesRedacted: redacted,
                              willPropagateToSyncReplicas: true, backupsThatMayStillContainData: backups, explanation: explanation)
    }

    private func executePurge(recordID: String, purgeOp: String) throws {
        _ = try? media.removeBlobIfUnreferenced(forRecord: recordID, excluding: [recordID])
        try db.execute("UPDATE ops SET sealed_values = ?, redacted = 1 WHERE record_id = ? AND op_id != ?", [.blob(Data()), .text(recordID), .text(purgeOp)])
        try db.execute("DELETE FROM records WHERE record_id = ?", [.text(recordID)])
        try db.execute("DELETE FROM field_heads WHERE record_id = ?", [.text(recordID)])
        try db.execute("DELETE FROM conflicts WHERE record_id = ?", [.text(recordID)])
        try db.execute("DELETE FROM observations WHERE source_id = ?", [.text(recordID)])
        index.remove(recordID)
    }

    // MARK: Devices

    public func trustedDevices() throws -> [DeviceRecord] {
        try all(DeviceRecord.self).filter { $0.revokedAt == nil }
    }

    /// Removes a device (e.g. a lost phone) from the household trust set. Changes it makes
    /// after this moment are rejected by every device that has synced the revocation.
    public func revokeDevice(_ id: String) throws {
        guard AccessPolicy.canManageDevices(try currentIdentity()) else { throw AccessError.notPermitted("revoke device") }
        guard var device = try fetch(DeviceRecord.self, id: id) else { throw HearthStoreError.recordNotFound(id) }
        device.revokedAt = clock.now()
        try save(device, provenance: .manual)
    }

    // MARK: Ops access (sync, backup, export)

    static func operation(from row: SQLRow) throws -> Operation {
        func json<T: Decodable>(_ t: T.Type, _ col: String) throws -> T {
            try HearthJSON.decoder.decode(t, from: Data((row.string(col) ?? "").utf8))
        }
        guard let id = row.string("op_id"), let hlc = row.string("hlc").flatMap(HLC.init) else {
            throw HearthStoreError.invalid("corrupt op row")
        }
        return Operation(id: id, hlc: hlc, actor: row.string("actor") ?? "", device: row.string("device") ?? "",
                         recordKind: RecordKind(rawValue: row.string("record_kind") ?? ""), recordID: row.string("record_id") ?? "",
                         action: Operation.Action(rawValue: row.string("action") ?? "") ?? .upsert,
                         fieldNames: try json([String].self, "field_names"), parents: try json([String: String].self, "parents"),
                         keyClass: row.string("key_class").flatMap(KeyClass.init) ?? .household,
                         sealedValues: row.data("sealed_values") ?? Data(), provenance: try json(Provenance.self, "provenance"))
    }

    public func operations(after hlc: HLC? = nil, authoredBy device: String? = nil) throws -> [Operation] {
        var sql = "SELECT * FROM ops WHERE 1 = 1"
        var params: [SQLValue] = []
        if let hlc { sql += " AND hlc > ?"; params.append(.text(hlc.description)) }
        if let device { sql += " AND device = ?"; params.append(.text(device)) }
        return try db.query(sql + " ORDER BY hlc", params).map(Self.operation(from:))
    }

    public func stats() throws -> [String: Int] {
        var out: [String: Int] = [:]
        for row in try db.query("SELECT kind, COUNT(*) AS n FROM records WHERE deleted = 0 GROUP BY kind") {
            out[row.string("kind") ?? "?"] = Int(row.int("n") ?? 0)
        }
        out["_ops"] = Int(try db.query("SELECT COUNT(*) AS n FROM ops").first?.int("n") ?? 0)
        out["_observations"] = Int(try db.query("SELECT COUNT(*) AS n FROM observations").first?.int("n") ?? 0)
        out["_blobs"] = Int(try db.query("SELECT COUNT(*) AS n FROM blobs").first?.int("n") ?? 0)
        return out
    }
}
