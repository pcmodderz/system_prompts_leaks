import Foundation

/// How a change came to exist. Stored with every operation; contains no content or secrets.
public struct Provenance: Codable, Hashable, Sendable {
    public enum Method: String, Codable, Sendable {
        case manual, capture, photoLibraryImport, shareSheet, fileImport, connector, ai, sync, restore, conflictResolution, system
    }
    public var method: Method
    /// e.g. connector id, share-extension source app, AI endpoint id.
    public var source: String?
    public var note: String?

    public init(_ method: Method, source: String? = nil, note: String? = nil) {
        self.method = method; self.source = source; self.note = note
    }
    public static let manual = Provenance(.manual)
    public static let system = Provenance(.system)
}

/// One change to one record. Operations are immutable, uniquely identified and
/// idempotent to apply, which is what makes offline edits and sync safe.
public struct Operation: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Sets the listed fields.
        case upsert
        /// Permanently removes the record's content everywhere ("deletion means deletion").
        case purge
    }

    public var id: String
    public var hlc: HLC
    public var actor: String
    public var device: String
    public var recordKind: RecordKind
    public var recordID: String
    public var action: Action
    /// Plaintext field names (not values) so heads can be tracked while the vault is locked.
    public var fieldNames: [String]
    /// For each field, the op the author last saw for that field. Used to tell a
    /// sequential edit from a concurrent (conflicting) one.
    public var parents: [String: String]
    public var keyClass: KeyClass
    /// AES-GCM sealed `[String: JSONValue]` with the key for `keyClass`, AAD = op id.
    public var sealedValues: Data
    public var provenance: Provenance
}

/// Decrypted history entry for display and export.
public struct HistoryEntry: Codable, Sendable {
    public var opID: String
    public var at: HLC
    public var actor: String
    public var device: String
    public var action: Operation.Action
    public var values: [String: JSONValue]?
    public var provenance: Provenance
    public var redacted: Bool
}

public struct Conflict: Codable, Sendable, Identifiable {
    public var id: String
    public var recordID: String
    public var field: String
    public var winningOp: String
    public var losingOp: String
    public var winningValue: JSONValue?
    public var losingValue: JSONValue?
    public var winningDevice: String?
    public var losingDevice: String?
    public var detectedAt: HLC
}

/// Current-state wrapper with the generic metadata every record carries.
public struct RecordEnvelope: Sendable {
    public var id: String
    public var kind: RecordKind
    public var fields: [String: JSONValue]
    public var keyClass: KeyClass
    public var createdAt: HLC
    public var updatedAt: HLC

    public var sensitivity: Sensitivity {
        fields["sensitivity"]?.stringValue.flatMap(Sensitivity.init(rawValue:)) ?? .normal
    }
    public var emergency: Bool { fields["emergency"]?.boolValue ?? false }
    public var deleted: Bool { fields["deleted"]?.boolValue ?? false }
    public var acl: [String]? { fields["acl"]?.arrayValue?.compactMap(\.stringValue) }
    public var categories: [SensitiveCategory] {
        fields["categories"]?.arrayValue?.compactMap { $0.stringValue.flatMap(SensitiveCategory.init(rawValue:)) } ?? []
    }
    public var title: String {
        for key in ["name", "title", "displayName", "caption", "originalFilename", "text"] {
            if let s = fields[key]?.stringValue, !s.isEmpty { return s }
        }
        return id
    }

    public func decode<R: HearthRecord>(_ type: R.Type) throws -> R {
        try JSONValue.decode(type, from: fields)
    }
}
