import Crypto
import Foundation

public enum MediaError: Error, Equatable {
    case blobMissing(String)
    case integrityFailure(expected: String, actual: String)
    case notAnOriginal(String)
    case originalsAreImmutable
}

/// Encrypted, content-addressed media.
///
/// - The *identity* of a media item is the SHA-256 of its plaintext bytes.
/// - On disk each blob is stored once at `media/<ab>/<blobID>.hblob`, where
///   `blobID = HMAC-SHA256(namingKey, sha256)` so file names don't reveal which
///   well-known file a household owns.
/// - Blobs are write-once. Originals are never rewritten; thumbnails, transcodes,
///   transcripts and AI analysis are separate `MediaObject`s with `derivedFrom` set.
/// - Importing the same bytes twice reuses the existing blob (and the existing original
///   record), so storage is not consumed twice.
public final class MediaStore: @unchecked Sendable {
    unowned let store: HearthStore
    init(store: HearthStore) { self.store = store }

    var directory: URL { store.root.appendingPathComponent("media") }

    func blobID(for sha256: String) throws -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(sha256.utf8), using: try store.keys.key(.mediaNaming))
        return Array(mac).hexString
    }

    func blobURL(blobID: String) -> URL {
        directory.appendingPathComponent(String(blobID.prefix(2))).appendingPathComponent("\(blobID).hblob")
    }

    public func blobURL(for media: MediaObject) throws -> URL { blobURL(blobID: try blobID(for: media.sha256)) }

    public func hasLocalBlob(_ media: MediaObject) -> Bool {
        (try? FileManager.default.fileExists(atPath: blobURL(for: media).path)) ?? false
    }

    // MARK: Import

    /// Imports an original from a file. The source file is not modified.
    @discardableResult
    public func importOriginal(file: URL, kind: MediaKind, mimeType: String, capturedAt: Date? = nil,
                               location: GeoPoint? = nil, caption: String? = nil, sensitivity: Sensitivity = .normal,
                               attachTo entityID: String? = nil, provenance: Provenance = Provenance(.fileImport)) throws -> MediaObject {
        let sha = try Hashing.sha256Hex(fileAt: file)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0

        if let existing = try all(role: .original).first(where: { $0.sha256 == sha }) {
            if let entityID { try store.link(existing.id, to: entityID, type: Relationship.attachedTo, provenance: provenance) }
            return existing
        }
        try storeBlob(from: file, sha256: sha, byteCount: size)
        let media = MediaObject(role: .original, mediaKind: kind, sha256: sha, byteCount: size, mimeType: mimeType,
                                originalFilename: file.lastPathComponent, capturedAt: capturedAt, location: location,
                                caption: caption, sensitivity: sensitivity)
        try store.save(media, provenance: provenance)
        if let entityID { try store.link(media.id, to: entityID, type: Relationship.attachedTo, provenance: provenance) }
        return media
    }

    @discardableResult
    public func importOriginal(data: Data, filename: String, kind: MediaKind, mimeType: String, capturedAt: Date? = nil,
                               location: GeoPoint? = nil, caption: String? = nil, sensitivity: Sensitivity = .normal,
                               attachTo entityID: String? = nil, provenance: Provenance = Provenance(.fileImport)) throws -> MediaObject {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(HearthIDs.new() + "-" + filename)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try importOriginal(file: tmp, kind: kind, mimeType: mimeType, capturedAt: capturedAt, location: location,
                                  caption: caption, sensitivity: sensitivity, attachTo: entityID, provenance: provenance)
    }

    /// Adds a derivative (thumbnail, transcript, OCR text, AI analysis...). Never touches the original.
    @discardableResult
    public func addDerivative(of original: MediaObject, role: MediaRole, data: Data, mimeType: String,
                              producedBy: String, provenance: Provenance = .system) throws -> MediaObject {
        guard role != .original else { throw MediaError.originalsAreImmutable }
        guard original.role == .original else { throw MediaError.notAnOriginal(original.id) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(HearthIDs.new())
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sha = Hashing.sha256Hex(data)
        try storeBlob(from: tmp, sha256: sha, byteCount: Int64(data.count))
        let kind: MediaKind = mimeType.hasPrefix("text/") || mimeType == "application/json" ? .text : original.mediaKind
        let derivative = MediaObject(role: role, mediaKind: kind, sha256: sha, byteCount: Int64(data.count),
                                     mimeType: mimeType, derivedFrom: original.id, producedBy: producedBy,
                                     sensitivity: original.sensitivity, categories: original.categories, acl: original.acl)
        try store.save(derivative, provenance: provenance)
        return derivative
    }

    func storeBlob(from file: URL, sha256: String, byteCount: Int64) throws {
        let id = try blobID(for: sha256)
        let dest = blobURL(blobID: id)
        if FileManager.default.fileExists(atPath: dest.path) { return } // content-addressed: already stored
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.appendingPathExtension("partial")
        try ChunkedCipher.encrypt(input: file, output: tmp, key: store.keys.key(.media))
        try FileManager.default.moveItem(at: tmp, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: dest.path)
        DataProtection.protect(dest, level: .media)
        try store.db.execute("INSERT OR IGNORE INTO blobs(sha256, blob_id, byte_count, stored_at) VALUES (?, ?, ?, ?)",
                             [.text(sha256), .text(id), .int(byteCount), .text(ISO8601DateFormatter().string(from: Date()))])
    }

    /// Adopts an already-encrypted blob (from sync or backup) after verifying it decrypts to `sha256`.
    func adoptEncryptedBlob(at url: URL, sha256: String) throws {
        let id = try blobID(for: sha256)
        let dest = blobURL(blobID: id)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        var hasher = SHA256()
        var count: Int64 = 0
        try ChunkedCipher.decrypt(input: url, key: store.keys.key(.media)) { hasher.update(data: $0); count += Int64($0.count) }
        let actual = hasher.finalize().hexString
        guard actual == sha256 else { throw MediaError.integrityFailure(expected: sha256, actual: actual) }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: dest)
        try? FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: dest.path)
        DataProtection.protect(dest, level: .media)
        try store.db.execute("INSERT OR IGNORE INTO blobs(sha256, blob_id, byte_count, stored_at) VALUES (?, ?, ?, ?)",
                             [.text(sha256), .text(id), .int(count), .text(ISO8601DateFormatter().string(from: Date()))])
    }

    // MARK: Read

    public func all(role: MediaRole? = nil) throws -> [MediaObject] {
        try store.all(MediaObject.self).filter { role == nil || $0.role == role }
    }

    public func derivatives(of original: MediaObject) throws -> [MediaObject] {
        try all().filter { $0.derivedFrom == original.id }
    }

    public func media(attachedTo entityID: String) throws -> [MediaObject] {
        let ids = Set(try store.relationships(of: entityID).filter { $0.to == entityID && $0.type == Relationship.attachedTo }.map(\.from))
        return try all().filter { ids.contains($0.id) }
    }

    /// Decrypts into memory, verifying integrity. Use `decrypt(_:to:)` for large video.
    public func data(for media: MediaObject) throws -> Data {
        let url = try blobURL(for: media)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.blobMissing(media.sha256) }
        var out = Data()
        try ChunkedCipher.decrypt(input: url, key: store.keys.key(.media)) { out.append($0) }
        let actual = Hashing.sha256Hex(out)
        guard actual == media.sha256 else { throw MediaError.integrityFailure(expected: media.sha256, actual: actual) }
        return out
    }

    /// Decrypts to a file (e.g. a protected temp file for AVPlayer) and verifies integrity.
    public func decrypt(_ media: MediaObject, to output: URL) throws {
        let url = try blobURL(for: media)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.blobMissing(media.sha256) }
        try ChunkedCipher.decrypt(input: url, output: output, key: store.keys.key(.media))
        DataProtection.protect(output, level: .media)
        let actual = try Hashing.sha256Hex(fileAt: output)
        guard actual == media.sha256 else {
            try? FileManager.default.removeItem(at: output)
            throw MediaError.integrityFailure(expected: media.sha256, actual: actual)
        }
    }

    // MARK: Integrity

    public struct IntegrityReport: Sendable {
        public var checked = 0
        public var missing: [String] = []
        public var corrupt: [String] = []
        public var ok: Bool { missing.isEmpty && corrupt.isEmpty }
    }

    public func verifyAll() throws -> IntegrityReport {
        var report = IntegrityReport()
        for media in try store.allEnvelopes(kind: .media, enforcePermissions: false).compactMap({ try? $0.decode(MediaObject.self) }) {
            report.checked += 1
            let url = try blobURL(for: media)
            guard FileManager.default.fileExists(atPath: url.path) else { report.missing.append(media.id); continue }
            var hasher = SHA256()
            do {
                try ChunkedCipher.decrypt(input: url, key: store.keys.key(.media)) { hasher.update(data: $0) }
                if hasher.finalize().hexString != media.sha256 { report.corrupt.append(media.id) }
            } catch {
                report.corrupt.append(media.id)
            }
        }
        return report
    }

    // MARK: Deletion

    /// Deletes a derivative. The original and other derivatives are untouched.
    public func deleteDerivative(_ derivative: MediaObject) throws {
        guard derivative.role != .original else { throw MediaError.originalsAreImmutable }
        try store.purge(derivative.id)
    }

    /// Removes the encrypted blob of a media record if no other surviving record uses it.
    func removeBlobIfUnreferenced(forRecord id: String, excluding: Set<String>) throws -> Int {
        guard let env = try store.envelope(id), env.kind == .media, let media = try? env.decode(MediaObject.self) else { return 0 }
        let stillUsed = try store.allEnvelopes(kind: .media, includeDeleted: true, enforcePermissions: false)
            .contains { !excluding.contains($0.id) && $0.fields["sha256"]?.stringValue == media.sha256 }
        guard !stillUsed else { return 0 }
        let url = try blobURL(for: media)
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try FileManager.default.removeItem(at: url)
        try store.db.execute("DELETE FROM blobs WHERE sha256 = ?", [.text(media.sha256)])
        return 1
    }
}
