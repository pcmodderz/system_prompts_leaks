import Foundation

/// Ordered, append-only schema migrations.
///
/// Rules (enforced by review, documented in docs/ARCHITECTURE.md):
/// - Never edit or delete a shipped migration; add a new one.
/// - Migrations may add tables/columns/indexes. They must not drop data.
/// - Record *content* lives in generic sealed field maps, so most model evolution
///   (new fields, renamed UI concepts) needs no SQL migration at all, and unknown
///   fields written by newer app versions are preserved by older ones.
enum Schema {
    static let migrations: [(version: Int, sql: String)] = [
        (1, """
        CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        -- Append-only operation log: the source of truth and the complete history.
        CREATE TABLE ops (
            op_id TEXT PRIMARY KEY,
            hlc TEXT NOT NULL,
            actor TEXT NOT NULL,
            device TEXT NOT NULL,
            record_kind TEXT NOT NULL,
            record_id TEXT NOT NULL,
            action TEXT NOT NULL,
            field_names TEXT NOT NULL,      -- JSON array
            parents TEXT NOT NULL,          -- JSON object field -> op_id
            key_class TEXT NOT NULL,        -- household | vault
            sealed_values BLOB NOT NULL,    -- AES-GCM sealed JSON object of field values
            provenance TEXT NOT NULL,       -- JSON (no secrets, no content)
            received_hlc TEXT NOT NULL,
            materialized INTEGER NOT NULL DEFAULT 0,
            redacted INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX ops_record ON ops(record_id, hlc);
        CREATE INDEX ops_hlc ON ops(hlc);
        CREATE INDEX ops_device ON ops(device, hlc);

        -- Materialized current state (derived from ops; can be rebuilt).
        CREATE TABLE records (
            record_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            key_class TEXT NOT NULL,
            sealed_fields BLOB NOT NULL,
            sensitivity TEXT NOT NULL,
            emergency INTEGER NOT NULL DEFAULT 0,
            deleted INTEGER NOT NULL DEFAULT 0,
            created_hlc TEXT NOT NULL,
            updated_hlc TEXT NOT NULL
        );
        CREATE INDEX records_kind ON records(kind, deleted);

        -- Winning op per (record, field): last-writer-wins register heads.
        CREATE TABLE field_heads (
            record_id TEXT NOT NULL,
            field TEXT NOT NULL,
            op_id TEXT NOT NULL,
            hlc TEXT NOT NULL,
            PRIMARY KEY (record_id, field)
        );

        -- Concurrent edits detected during merge. Both values stay in the op log.
        CREATE TABLE conflicts (
            conflict_id TEXT PRIMARY KEY,
            record_id TEXT NOT NULL,
            field TEXT NOT NULL,
            winning_op TEXT NOT NULL,
            losing_op TEXT NOT NULL,
            detected_hlc TEXT NOT NULL,
            resolved_op TEXT
        );

        -- Content-addressed encrypted blobs (local cache of media bytes).
        CREATE TABLE blobs (
            sha256 TEXT PRIMARY KEY,
            blob_id TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            stored_at TEXT NOT NULL
        );

        -- Live data: every observation is kept (history), sealed.
        CREATE TABLE observations (
            observation_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            metric TEXT NOT NULL,
            observed_at REAL NOT NULL,
            fetched_at REAL NOT NULL,
            sealed_value BLOB NOT NULL
        );
        CREATE INDEX observations_source ON observations(source_id, metric, observed_at);

        CREATE TABLE source_status (
            source_id TEXT PRIMARY KEY,
            last_attempt REAL,
            last_success REAL,
            last_error TEXT,
            last_error_kind TEXT
        );

        -- Sync bookkeeping (local only).
        CREATE TABLE sync_imported (
            transport_id TEXT NOT NULL,
            bundle_name TEXT NOT NULL,
            imported_hlc TEXT NOT NULL,
            PRIMARY KEY (transport_id, bundle_name)
        );
        CREATE TABLE sync_watermarks (
            transport_id TEXT PRIMARY KEY,
            last_pushed_hlc TEXT NOT NULL
        );

        -- External AI: remembered approvals and an audit trail of every disclosure.
        CREATE TABLE ai_grants (
            grant_id TEXT PRIMARY KEY,
            endpoint_id TEXT NOT NULL,
            purpose TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE ai_disclosures (
            disclosure_id TEXT PRIMARY KEY,
            endpoint_id TEXT NOT NULL,
            purpose TEXT NOT NULL,
            classification TEXT NOT NULL,
            decision TEXT NOT NULL,
            at REAL NOT NULL
        );

        -- Backups this device made, and whether a test restore has proven them.
        CREATE TABLE backup_log (
            backup_id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            location TEXT NOT NULL,
            verified_at REAL,
            test_restored_at REAL
        );
        """),
    ]

    static func migrate(_ db: SQLiteDatabase) throws {
        try db.executeScript("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)")
        let applied = Set(try db.query("SELECT version FROM schema_migrations").compactMap { $0.int("version") })
        for (version, sql) in migrations where !applied.contains(Int64(version)) {
            try db.transaction {
                try db.executeScript(sql)
                try db.execute("INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
                               [.int(Int64(version)), .double(Date().timeIntervalSince1970)])
            }
        }
    }

    static var currentVersion: Int { migrations.map(\.version).max() ?? 0 }
}
