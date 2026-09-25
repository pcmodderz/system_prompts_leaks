import Foundation

public enum HearthIDs {
    public static func new() -> String { UUID().uuidString.lowercased() }
}

/// How carefully a record must be handled.
public enum Sensitivity: String, Codable, Comparable, CaseIterable, Sendable {
    /// Household-visible, sealed with the household key, indexed for search.
    case normal
    /// Visible to the owner and to identities listed in `acl` (adults if `acl` is nil).
    case `private`
    /// Sealed with the vault key; needs Face ID / Touch ID / passcode to open; never
    /// indexed at rest; never sent to external AI.
    case restricted

    public static func < (a: Sensitivity, b: Sensitivity) -> Bool {
        let order: [Sensitivity] = [.normal, .private, .restricted]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

/// Categories that drive extra protection (see `SensitivityPolicy`).
public enum SensitiveCategory: String, Codable, CaseIterable, Sendable {
    case financial, identity, insurance, medical, security, network, familyPrivate, emergency
}

public struct RecordKind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let household: RecordKind = "household"
    public static let identity: RecordKind = "identity"
    public static let device: RecordKind = "device"
    public static let entity: RecordKind = "entity"
    public static let relationship: RecordKind = "relationship"
    public static let event: RecordKind = "event"
    public static let procedure: RecordKind = "procedure"
    public static let media: RecordKind = "media"
    public static let annotation: RecordKind = "annotation"
    public static let liveSource: RecordKind = "live_source"
}

/// Every stored record type. Common protection metadata is flat so that it merges per field.
public protocol HearthRecord: Codable, Sendable {
    static var kind: RecordKind { get }
    var id: String { get }
    var sensitivity: Sensitivity { get }
    var emergency: Bool { get }
    /// Identities allowed to read a `private` record. `nil` = household adults.
    var acl: [String]? { get }
    var categories: [SensitiveCategory] { get }
    var deleted: Bool { get }
}

public extension HearthRecord {
    var acl: [String]? { nil }
    var categories: [SensitiveCategory] { [] }
}

// MARK: - Household & people

public struct Household: HearthRecord, Equatable {
    public static let kind = RecordKind.household
    public var id: String
    public var name: String
    public var createdAt: Date
    public var sensitivity: Sensitivity = .normal
    public var emergency = false
    public var deleted = false
    public init(id: String = HearthIDs.new(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

public enum HouseholdRole: String, Codable, CaseIterable, Sendable {
    case owner, adult, child, guest, emergencyAccess
}

public struct Identity: HearthRecord, Equatable {
    public static let kind = RecordKind.identity
    public var id: String
    public var displayName: String
    public var role: HouseholdRole
    public var sensitivity: Sensitivity = .normal
    public var emergency = false
    public var deleted = false
    public init(id: String = HearthIDs.new(), displayName: String, role: HouseholdRole) {
        self.id = id; self.displayName = displayName; self.role = role
    }
}

public struct DeviceRecord: HearthRecord, Equatable {
    public static let kind = RecordKind.device
    public var id: String
    public var name: String
    public var platform: String
    public var ownerIdentity: String
    public var enrolledAt: Date
    /// Set when the device is removed from the household trust set (e.g. lost phone).
    /// Operations it authored after this timestamp are rejected during sync.
    public var revokedAt: HLC?
    public var sensitivity: Sensitivity = .normal
    public var emergency = false
    public var deleted = false
    public init(id: String, name: String, platform: String, ownerIdentity: String, enrolledAt: Date = Date()) {
        self.id = id; self.name = name; self.platform = platform
        self.ownerIdentity = ownerIdentity; self.enrolledAt = enrolledAt
    }
}

// MARK: - Household graph

public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double?
    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double? = nil) {
        self.latitude = latitude; self.longitude = longitude; self.horizontalAccuracy = horizontalAccuracy
    }
    /// Coarsened copy for minimum-necessary disclosure (0.1° ≈ 11 km).
    public func coarsened(decimals: Int = 1) -> GeoPoint {
        let f = pow(10, Double(decimals))
        return GeoPoint(latitude: (latitude * f).rounded() / f, longitude: (longitude * f).rounded() / f)
    }
}

/// Anything in the household: the house, rooms, appliances, vehicles, pets, people,
/// utilities, accounts, networks, documents. `kindName` is open-ended on purpose.
public struct Entity: HearthRecord, Equatable {
    public static let kind = RecordKind.entity
    public var id: String
    public var kindName: String
    public var name: String
    public var notes: String?
    public var attributes: [String: String]
    public var location: GeoPoint?
    public var sensitivity: Sensitivity
    public var categories: [SensitiveCategory]
    public var acl: [String]?
    public var emergency: Bool
    public var deleted = false

    public init(id: String = HearthIDs.new(), kindName: String, name: String, notes: String? = nil,
                attributes: [String: String] = [:], location: GeoPoint? = nil,
                sensitivity: Sensitivity = .normal, categories: [SensitiveCategory] = [],
                acl: [String]? = nil, emergency: Bool = false) {
        self.id = id; self.kindName = kindName; self.name = name; self.notes = notes
        self.attributes = attributes; self.location = location; self.sensitivity = sensitivity
        self.categories = categories; self.acl = acl; self.emergency = emergency
    }
}

/// Directed edge between any two records (entity↔entity, media→entity, event→entity...).
public struct Relationship: HearthRecord, Equatable {
    public static let kind = RecordKind.relationship
    public var id: String
    public var from: String
    public var to: String
    public var type: String
    public var sensitivity: Sensitivity = .normal
    public var emergency = false
    public var deleted = false
    public init(id: String = HearthIDs.new(), from: String, to: String, type: String) {
        self.id = id; self.from = from; self.to = to; self.type = type
    }

    public static let attachedTo = "attached_to"
    public static let locatedIn = "located_in"
    public static let shutoffFor = "shutoff_for"
    public static let services = "services"
}

public enum EventKind: String, Codable, CaseIterable, Sendable {
    case note, maintenance, repair, purchase, incident, capture, inspection, reminder
}

public struct HouseholdEvent: HearthRecord, Equatable {
    public static let kind = RecordKind.event
    public var id: String
    public var eventKind: EventKind
    public var title: String
    public var body: String?
    public var entityIDs: [String]
    public var occurredAt: Date
    public var dueAt: Date?
    public var completedAt: Date?
    public var cost: String?
    public var sensitivity: Sensitivity
    public var categories: [SensitiveCategory]
    public var acl: [String]?
    public var emergency = false
    public var deleted = false

    public init(id: String = HearthIDs.new(), eventKind: EventKind, title: String, body: String? = nil,
                entityIDs: [String] = [], occurredAt: Date = Date(), dueAt: Date? = nil,
                completedAt: Date? = nil, cost: String? = nil, sensitivity: Sensitivity = .normal,
                categories: [SensitiveCategory] = [], acl: [String]? = nil) {
        self.id = id; self.eventKind = eventKind; self.title = title; self.body = body
        self.entityIDs = entityIDs; self.occurredAt = occurredAt; self.dueAt = dueAt
        self.completedAt = completedAt; self.cost = cost; self.sensitivity = sensitivity
        self.categories = categories; self.acl = acl
    }
}

/// Step-by-step instructions. Emergency procedures are always readable offline and
/// never require AI or the vault.
public struct Procedure: HearthRecord, Equatable {
    public static let kind = RecordKind.procedure
    public var id: String
    public var title: String
    public var summary: String?
    public var steps: [String]
    public var entityIDs: [String]
    public var sensitivity: Sensitivity
    public var categories: [SensitiveCategory]
    public var acl: [String]?
    public var emergency: Bool
    public var deleted = false

    public init(id: String = HearthIDs.new(), title: String, summary: String? = nil, steps: [String],
                entityIDs: [String] = [], sensitivity: Sensitivity = .normal,
                categories: [SensitiveCategory] = [], acl: [String]? = nil, emergency: Bool = false) {
        self.id = id; self.title = title; self.summary = summary; self.steps = steps
        self.entityIDs = entityIDs; self.sensitivity = sensitivity; self.categories = categories
        self.acl = acl; self.emergency = emergency
    }
}

public struct Annotation: HearthRecord, Equatable {
    public static let kind = RecordKind.annotation
    public var id: String
    public var target: String
    public var text: String
    public var createdAt: Date
    public var sensitivity: Sensitivity = .normal
    public var emergency = false
    public var deleted = false
    public init(id: String = HearthIDs.new(), target: String, text: String, createdAt: Date = Date()) {
        self.id = id; self.target = target; self.text = text; self.createdAt = createdAt
    }
}

// MARK: - Media

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case photo, video, audio, document, text, web
}

/// Originals are immutable. Everything else is a separate object pointing at its original.
public enum MediaRole: String, Codable, CaseIterable, Sendable {
    case original, derived, thumbnail, transcode, aiAnalysis, transcript, ocrText
}

public struct MediaObject: HearthRecord, Equatable {
    public static let kind = RecordKind.media
    public var id: String
    public var role: MediaRole
    public var mediaKind: MediaKind
    /// SHA-256 of the plaintext bytes: identity, integrity check and dedup key.
    public var sha256: String
    public var byteCount: Int64
    public var mimeType: String
    public var originalFilename: String?
    public var derivedFrom: String?
    public var capturedAt: Date?
    public var importedAt: Date
    public var location: GeoPoint?
    public var durationSeconds: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var caption: String?
    /// Which processing produced a derivative (e.g. "device.vision.ocr", "lan.whisper").
    public var producedBy: String?
    public var sensitivity: Sensitivity
    public var categories: [SensitiveCategory]
    public var acl: [String]?
    public var emergency = false
    public var deleted = false

    public init(id: String = HearthIDs.new(), role: MediaRole, mediaKind: MediaKind, sha256: String,
                byteCount: Int64, mimeType: String, originalFilename: String? = nil,
                derivedFrom: String? = nil, capturedAt: Date? = nil, importedAt: Date = Date(),
                location: GeoPoint? = nil, caption: String? = nil, producedBy: String? = nil,
                sensitivity: Sensitivity = .normal, categories: [SensitiveCategory] = [], acl: [String]? = nil) {
        self.id = id; self.role = role; self.mediaKind = mediaKind; self.sha256 = sha256
        self.byteCount = byteCount; self.mimeType = mimeType; self.originalFilename = originalFilename
        self.derivedFrom = derivedFrom; self.capturedAt = capturedAt; self.importedAt = importedAt
        self.location = location; self.caption = caption; self.producedBy = producedBy
        self.sensitivity = sensitivity; self.categories = categories; self.acl = acl
    }
}

// MARK: - Live data configuration (no secrets; credentials live in the CredentialStore)

public struct LiveSource: HearthRecord, Equatable {
    public static let kind = RecordKind.liveSource
    public var id: String
    public var connector: String
    public var name: String
    public var entityID: String?
    public var config: [String: String]
    /// Keychain account name of the credential, never the credential itself.
    public var credentialRef: String?
    /// Data older than this is shown as STALE.
    public var maxAgeSeconds: Double
    public var enabled: Bool
    public var sensitivity: Sensitivity = .normal
    public var emergency = false
    public var deleted = false

    public init(id: String = HearthIDs.new(), connector: String, name: String, entityID: String? = nil,
                config: [String: String], credentialRef: String? = nil, maxAgeSeconds: Double = 3600,
                enabled: Bool = true) {
        self.id = id; self.connector = connector; self.name = name; self.entityID = entityID
        self.config = config; self.credentialRef = credentialRef; self.maxAgeSeconds = maxAgeSeconds
        self.enabled = enabled
    }
}
