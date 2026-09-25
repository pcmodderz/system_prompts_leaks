import Crypto
import Foundation

/// Drop box for things shared into Hearth from other apps (Share → Hearth).
///
/// The share extension never holds household keys. The main app publishes an X25519
/// *public* key; the extension seals each item to it (ephemeral ECDH + HKDF + AES-GCM),
/// so items waiting in the shared App Group container are unreadable to anyone but the
/// main app, which holds the private key in the Keychain.
public struct InboxItemMetadata: Codable, Sendable, Equatable {
    public var filename: String
    public var mimeType: String
    public var kind: MediaKind
    public var sourceApp: String?
    public var sharedText: String?
    public var sharedURL: String?
    public var receivedAt: Date
    public init(filename: String, mimeType: String, kind: MediaKind, sourceApp: String? = nil,
                sharedText: String? = nil, sharedURL: String? = nil, receivedAt: Date = Date()) {
        self.filename = filename; self.mimeType = mimeType; self.kind = kind; self.sourceApp = sourceApp
        self.sharedText = sharedText; self.sharedURL = sharedURL; self.receivedAt = receivedAt
    }
}

public enum InboxSealer {
    struct Envelope: Codable {
        var format = "hearth-inbox-v1"
        var ephemeralPublicKey: Data
        var salt: Data
        var sealedMetadata: Data
        var sealedPayload: Data
    }

    static func derive(_ shared: SharedSecret, salt: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("hearth.inbox.v1".utf8), outputByteCount: 32)
    }

    /// Used by the share extension. Only needs the inbox public key.
    public static func seal(_ payload: Data, metadata: InboxItemMetadata, to publicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let eph = Curve25519.KeyAgreement.PrivateKey()
        var salt = Data(count: 16)
        for i in 0..<16 { salt[i] = UInt8.random(in: 0...255) }
        let key = derive(try eph.sharedSecretFromKeyAgreement(with: publicKey), salt: salt)
        let env = Envelope(ephemeralPublicKey: eph.publicKey.rawRepresentation, salt: salt,
                           sealedMetadata: try Sealer.sealJSON(metadata, key: key, aad: Data("meta".utf8)),
                           sealedPayload: try Sealer.seal(payload, key: key, aad: Data("payload".utf8)))
        return try HearthJSON.encoder.encode(env)
    }

    public static func open(_ data: Data, with privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> (InboxItemMetadata, Data) {
        let env = try HearthJSON.decoder.decode(Envelope.self, from: data)
        let eph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: env.ephemeralPublicKey)
        let key = derive(try privateKey.sharedSecretFromKeyAgreement(with: eph), salt: env.salt)
        return (try Sealer.openJSON(InboxItemMetadata.self, env.sealedMetadata, key: key, aad: Data("meta".utf8)),
                try Sealer.open(env.sealedPayload, key: key, aad: Data("payload".utf8)))
    }
}

public struct PendingInboxItem: Sendable {
    public var file: URL
    public var metadata: InboxItemMetadata
    public var payload: Data
}

public extension HearthStore {
    var inboxDirectory: URL { root.appendingPathComponent("inbox") }

    /// Items shared from other apps that still need to be attached to an entity or event.
    func pendingInboxItems(privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> [PendingInboxItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: inboxDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "hinbox" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let (meta, payload) = try? InboxSealer.open(data, with: privateKey) else { return nil }
            return PendingInboxItem(file: url, metadata: meta, payload: payload)
        }
    }

    /// Files an inbox item: imports it as an original (or a note for text/links), links it to
    /// `entityID` if given, then removes it from the inbox.
    @discardableResult
    func fileInboxItem(_ item: PendingInboxItem, attachTo entityID: String?, eventID: String? = nil) throws -> String {
        let provenance = Provenance(.shareSheet, source: item.metadata.sourceApp)
        let id: String
        if item.payload.isEmpty {
            let note = HouseholdEvent(eventKind: .note, title: item.metadata.sharedText ?? item.metadata.sharedURL ?? item.metadata.filename,
                                      body: [item.metadata.sharedText, item.metadata.sharedURL].compactMap { $0 }.joined(separator: "\n"),
                                      entityIDs: entityID.map { [$0] } ?? [], occurredAt: item.metadata.receivedAt)
            try save(note, provenance: provenance)
            id = note.id
        } else {
            let m = try media.importOriginal(data: item.payload, filename: item.metadata.filename, kind: item.metadata.kind,
                                             mimeType: item.metadata.mimeType, caption: item.metadata.sharedText,
                                             attachTo: entityID, provenance: provenance)
            if let eventID { try link(m.id, to: eventID, type: Relationship.attachedTo, provenance: provenance) }
            id = m.id
        }
        try FileManager.default.removeItem(at: item.file)
        return id
    }
}
