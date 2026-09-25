import Foundation

/// A place bundles can be exchanged. Hearth's data model knows nothing about the transport;
/// replicas hold copies, ownership never moves.
///
/// Implementations: `DirectorySyncTransport` (NAS/SMB/AFP mount, Syncthing folder, USB drive,
/// a user-chosen iCloud Drive or other cloud folder). Future: peer-to-peer (Multipeer /
/// Network.framework), household server over HTTPS.
public protocol SyncTransport: Sendable {
    var id: String { get }
    func listBundles() throws -> [String]
    func readBundle(_ name: String) throws -> Data
    func writeBundle(_ name: String, data: Data) throws
    func listBlobs() throws -> Set<String>
    func readBlob(_ blobID: String, to url: URL) throws
    func writeBlob(_ blobID: String, from url: URL) throws
}

/// Shared-folder transport. Layout:
///
///     <folder>/bundles/<deviceID>/<hlc>-<uuid>.hsync   sealed op bundles (append-only)
///     <folder>/blobs/<blobID>.hblob                     encrypted media blobs
///
/// Everything written is encrypted with household keys, so the folder may live on hardware
/// or cloud storage the household does not fully trust.
public struct DirectorySyncTransport: SyncTransport {
    public let folder: URL
    public var id: String { "dir:" + folder.standardizedFileURL.path }

    public init(folder: URL) throws {
        self.folder = folder
        for sub in ["bundles", "blobs"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    public func listBundles() throws -> [String] {
        let base = folder.appendingPathComponent("bundles")
        var names: [String] = []
        for device in try FileManager.default.contentsOfDirectory(atPath: base.path) {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent(device).path)) ?? []
            where file.hasSuffix(".hsync") {
                names.append("\(device)/\(file)")
            }
        }
        return names.sorted()
    }

    public func readBundle(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appendingPathComponent("bundles").appendingPathComponent(name))
    }

    public func writeBundle(_ name: String, data: Data) throws {
        let url = folder.appendingPathComponent("bundles").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func listBlobs() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("blobs").path)
            .filter { $0.hasSuffix(".hblob") }.map { String($0.dropLast(6)) })
    }

    public func readBlob(_ blobID: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("blobs/\(blobID).hblob"), to: url)
    }

    public func writeBlob(_ blobID: String, from url: URL) throws {
        let dest = folder.appendingPathComponent("blobs/\(blobID).hblob")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        let tmp = dest.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: url, to: tmp)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

struct SyncBundle: Codable {
    var format = "hearth-sync-bundle-v1"
    var householdID: String
    var fromDevice: String
    var createdAt: HLC
    var ops: [Operation]
    /// sha256 -> blobID for media blobs this bundle's records reference.
    var blobs: [String: String]
}

public struct SyncReport: Sendable, CustomStringConvertible {
    public var pushedOps = 0
    public var pushedBlobs = 0
    public var bundlesRead = 0
    public var applied = 0
    public var duplicates = 0
    public var deferred = 0
    public var rejected: [String] = []
    public var blobsFetched = 0
    public var newConflicts = 0
    public var description: String {
        "pushed \(pushedOps) ops/\(pushedBlobs) blobs; read \(bundlesRead) bundles; applied \(applied), duplicates \(duplicates), deferred \(deferred), rejected \(rejected.count), blobs fetched \(blobsFetched), new conflicts \(newConflicts)"
    }
}

public extension HearthStore {
    /// Pushes this device's new operations and media, then pulls and merges everyone else's.
    /// Safe to run at any time, any number of times, in any order across devices.
    func sync(with transport: SyncTransport) throws -> SyncReport {
        var report = SyncReport()
        let conflictsBefore = try conflicts(includeResolved: true).count
        let syncKey = try keys.key(.sync)

        // Push: only operations authored on this device (others relay their own).
        let watermark = try db.query("SELECT last_pushed_hlc FROM sync_watermarks WHERE transport_id = ?", [.text(transport.id)])
            .first?.string("last_pushed_hlc").flatMap(HLC.init)
        let outgoing = try operations(after: watermark, authoredBy: deviceID)
        if let last = outgoing.last {
            var blobs: [String: String] = [:]
            for op in outgoing where op.recordKind == .media {
                if let env = try? envelope(op.recordID), let sha = env.fields["sha256"]?.stringValue {
                    let blobID = try media.blobID(for: sha)
                    let url = media.blobURL(blobID: blobID)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try transport.writeBlob(blobID, from: url)
                        blobs[sha] = blobID
                        report.pushedBlobs += 1
                    }
                }
            }
            let bundle = SyncBundle(householdID: householdID, fromDevice: deviceID, createdAt: clock.now(), ops: outgoing, blobs: blobs)
            let name = "\(deviceID)/\(bundle.createdAt.description)-\(HearthIDs.new()).hsync"
            try transport.writeBundle(name, data: Sealer.sealJSON(bundle, key: syncKey, aad: Data(householdID.utf8)))
            try db.execute("INSERT INTO sync_imported(transport_id, bundle_name, imported_hlc) VALUES (?, ?, ?)",
                           [.text(transport.id), .text(name), .text(clock.now().description)])
            try db.execute("INSERT INTO sync_watermarks(transport_id, last_pushed_hlc) VALUES (?, ?) ON CONFLICT(transport_id) DO UPDATE SET last_pushed_hlc = excluded.last_pushed_hlc",
                           [.text(transport.id), .text(last.hlc.description)])
            report.pushedOps = outgoing.count
        }

        // Pull.
        let imported = Set(try db.query("SELECT bundle_name FROM sync_imported WHERE transport_id = ?", [.text(transport.id)]).compactMap { $0.string("bundle_name") })
        let remoteBlobs = try transport.listBlobs()
        // Read every new bundle first and apply them as one batch, so a device's enrollment
        // record is known before its own operations are checked, whatever the file order.
        var bundles: [(name: String, bundle: SyncBundle)] = []
        for name in try transport.listBundles() where !imported.contains(name) {
            do {
                bundles.append((name, try Sealer.openJSON(SyncBundle.self, transport.readBundle(name), key: syncKey, aad: Data(householdID.utf8))))
            } catch {
                report.rejected.append("\(name): cannot open (different household or corrupted)")
            }
        }
        report.bundlesRead = bundles.count
        var bundleOf: [String: String] = [:]
        for (name, b) in bundles { for op in b.ops { bundleOf[op.id] = name } }
        let allOps = bundles.flatMap(\.bundle.ops)
        let ordered = allOps.filter { $0.recordKind == .device }.sorted { $0.hlc < $1.hlc }
            + allOps.filter { $0.recordKind != .device }.sorted { $0.hlc < $1.hlc }
        var retryLater = Set<String>()
        for op in ordered {
            switch try apply(op, source: .sync) {
            case .applied: report.applied += 1
            case .duplicate: report.duplicates += 1
            case .deferredUntilVaultUnlocked: report.deferred += 1
            case .rejected(let why):
                report.rejected.append(why)
                // Unknown device: its enrollment may arrive in a later bundle; try again next sync.
                if why.hasPrefix("operation from unknown device"), let n = bundleOf[op.id] { retryLater.insert(n) }
            }
        }
        for (name, bundle) in bundles {
            for (sha, blobID) in bundle.blobs where remoteBlobs.contains(blobID) {
                let local = media.blobURL(blobID: blobID)
                if FileManager.default.fileExists(atPath: local.path) { continue }
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(HearthIDs.new())
                defer { try? FileManager.default.removeItem(at: tmp) }
                try transport.readBlob(blobID, to: tmp)
                try media.adoptEncryptedBlob(at: tmp, sha256: sha)
                report.blobsFetched += 1
            }
            if !retryLater.contains(name) {
                try db.execute("INSERT OR IGNORE INTO sync_imported(transport_id, bundle_name, imported_hlc) VALUES (?, ?, ?)",
                               [.text(transport.id), .text(name), .text(clock.now().description)])
            }
        }
        report.newConflicts = try conflicts(includeResolved: true).count - conflictsBefore
        return report
    }
}
