import Foundation

/// Writes the household in open formats that need no Hearth software to read:
/// JSON, JSON Lines, Markdown, and the original media files named by their SHA-256.
///
///     README.md                     what everything is
///     manifest.json                 every file with SHA-256 + byte count
///     household.json                household, people, devices
///     records/<kind>.json           current state of every record, by kind
///     graph/relationships.json      edges; graph/graph.dot for Graphviz
///     history/operations.jsonl      complete change history (decrypted), one op per line
///     procedures/<title>.md         human-readable procedures
///     EMERGENCY.md                  every emergency record, printable
///     media/originals/<sha256>.<ext>
///     media/derived/<sha256>.<ext>  thumbnails, transcripts, AI analysis
///     media/index.json              metadata for each media file
///     live/observations.jsonl       stored live-data history
public enum Exporter {
    public struct Options: Sendable {
        public var includeRestricted = false
        public var stripLocation = false
        public var includeMedia = true
        public init(includeRestricted: Bool = false, stripLocation: Bool = false, includeMedia: Bool = true) {
            self.includeRestricted = includeRestricted; self.stripLocation = stripLocation; self.includeMedia = includeMedia
        }
    }

    public struct Result: Sendable {
        public var directory: URL
        public var recordCount: Int
        public var mediaCount: Int
        public var fileCount: Int
        public var skippedRestricted: Int
    }

    public static func export(_ store: HearthStore, to parent: URL, options: Options = Options()) throws -> Result {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dir = parent.appendingPathComponent("Hearth-Export-\(stamp)")
        for sub in ["records", "graph", "history", "procedures", "media/originals", "media/derived", "live"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        if options.includeRestricted { try store.unlockVault() }

        var envs = try store.allEnvelopes(kind: nil, includeDeleted: false)
        var skipped = 0
        if !options.includeRestricted {
            skipped = envs.filter { $0.sensitivity == .restricted }.count + (try store.lockedCount())
            envs.removeAll { $0.sensitivity == .restricted }
        }
        let exportedIDs = Set(envs.map(\.id))
        func clean(_ fields: [String: JSONValue]) -> [String: JSONValue] {
            var f = fields
            if options.stripLocation { f["location"] = nil }
            return f.filter { $0.value != .null }
        }
        func write(_ value: some Encodable, _ rel: String) throws {
            try HearthJSON.prettyEncoder.encode(value).write(to: dir.appendingPathComponent(rel))
        }

        // Records by kind
        let byKind = Dictionary(grouping: envs, by: \.kind.rawValue)
        for (kind, items) in byKind {
            let rows: [JSONValue] = items.sorted { $0.createdAt < $1.createdAt }.map { env in
                var f = clean(env.fields)
                f["id"] = .string(env.id)
                f["_createdAt"] = .string(ISO8601DateFormatter().string(from: env.createdAt.date))
                f["_updatedAt"] = .string(ISO8601DateFormatter().string(from: env.updatedAt.date))
                return .object(f)
            }
            try write(rows, "records/\(kind).json")
        }
        try write([
            "household": .array((byKind["household"] ?? []).map { .object(clean($0.fields)) }),
            "people": .array((byKind["identity"] ?? []).map { .object(clean($0.fields)) }),
            "devices": .array((byKind["device"] ?? []).map { .object(clean($0.fields)) }),
        ] as [String: JSONValue], "household.json")

        // Graph
        let rels = (byKind["relationship"] ?? []).compactMap { try? $0.decode(Relationship.self) }
            .filter { exportedIDs.contains($0.from) && exportedIDs.contains($0.to) }
        try write(rels, "graph/relationships.json")
        let titles = Dictionary(uniqueKeysWithValues: envs.map { ($0.id, $0.title) })
        var dot = "digraph household {\n  rankdir=LR;\n"
        for id in Set(rels.flatMap { [$0.from, $0.to] }).sorted() {
            dot += "  \"\(id)\" [label=\"\((titles[id] ?? id).replacingOccurrences(of: "\"", with: "'"))\"];\n"
        }
        for r in rels { dot += "  \"\(r.from)\" -> \"\(r.to)\" [label=\"\(r.type)\"];\n" }
        dot += "}\n"
        try dot.write(to: dir.appendingPathComponent("graph/graph.dot"), atomically: true, encoding: .utf8)

        // History
        var lines = ""
        for id in exportedIDs.sorted() {
            for h in try store.history(of: id) {
                var entry = h
                if options.stripLocation { entry.values?["location"] = nil }
                lines += String(decoding: try HearthJSON.encoder.encode(HistoryLine(recordID: id, entry: entry)), as: UTF8.self) + "\n"
            }
        }
        try lines.write(to: dir.appendingPathComponent("history/operations.jsonl"), atomically: true, encoding: .utf8)

        // Procedures & emergency
        let procedures = (byKind["procedure"] ?? []).compactMap { try? $0.decode(Procedure.self) }
        for p in procedures {
            try Markdown.procedure(p, titles: titles).write(to: dir.appendingPathComponent("procedures/\(slug(p.title))-\(p.id.prefix(6)).md"), atomically: true, encoding: .utf8)
        }
        try Markdown.emergency(envs.filter(\.emergency), procedures: procedures, titles: titles)
            .write(to: dir.appendingPathComponent("EMERGENCY.md"), atomically: true, encoding: .utf8)

        // Media
        var mediaCount = 0
        var mediaIndex: [JSONValue] = []
        if options.includeMedia {
            for env in byKind["media"] ?? [] {
                guard let m = try? env.decode(MediaObject.self) else { continue }
                let folder = m.role == .original ? "originals" : "derived"
                let rel = "media/\(folder)/\(m.sha256).\(fileExtension(m))"
                let out = dir.appendingPathComponent(rel)
                if !fm.fileExists(atPath: out.path) {
                    do { try store.media.decrypt(m, to: out) } catch { continue }
                }
                mediaCount += 1
                var f = clean(env.fields)
                f["id"] = .string(env.id)
                f["file"] = .string(rel)
                mediaIndex.append(.object(f))
            }
        }
        try write(mediaIndex, "media/index.json")

        // Live data history
        var obs = ""
        for source in (byKind["live_source"] ?? []).compactMap({ try? $0.decode(LiveSource.self) }) {
            for o in try store.live.observations(sourceID: source.id, limit: Int.max / 2) {
                obs += String(decoding: try HearthJSON.encoder.encode(o), as: UTF8.self) + "\n"
            }
        }
        try obs.write(to: dir.appendingPathComponent("live/observations.jsonl"), atomically: true, encoding: .utf8)

        try readme(options: options, skipped: skipped).write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        // Manifest with checksums of everything
        var entries: [JSONValue] = []
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1))
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(.object(["path": .string(rel), "sha256": .string(try Hashing.sha256Hex(fileAt: url)), "bytes": .number(Double(size))]))
        }
        entries.sort { ($0.objectPath ?? "") < ($1.objectPath ?? "") }
        try write([
            "format": .string("hearth-export-v1"),
            "householdID": .string(store.householdID),
            "exportedAt": .string(ISO8601DateFormatter().string(from: Date())),
            "locationStripped": .bool(options.stripLocation),
            "restrictedIncluded": .bool(options.includeRestricted),
            "files": .array(entries),
        ] as [String: JSONValue], "manifest.json")

        return Result(directory: dir, recordCount: envs.count, mediaCount: mediaCount, fileCount: entries.count + 1, skippedRestricted: skipped)
    }

    struct HistoryLine: Encodable { var recordID: String; var entry: HistoryEntry }

    static func slug(_ s: String) -> String {
        let allowed = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-").prefix(60).description
    }

    static func fileExtension(_ m: MediaObject) -> String {
        if let name = m.originalFilename, let ext = name.split(separator: ".").last, name.contains(".") { return String(ext).lowercased() }
        switch m.mimeType {
        case "image/jpeg": return "jpg"
        case "image/heic": return "heic"
        case "image/png": return "png"
        case "video/quicktime": return "mov"
        case "video/mp4": return "mp4"
        case "audio/m4a", "audio/mp4": return "m4a"
        case "application/pdf": return "pdf"
        case "application/json": return "json"
        default: return m.mimeType.hasPrefix("text/") ? "txt" : "bin"
        }
    }

    static func readme(options: Options, skipped: Int) -> String {
        """
        # Hearth household export

        This folder is your household's data in open formats. You do not need Hearth to use it.

        - `household.json` — the household, its people and devices
        - `records/*.json` — every record's current state, one file per kind
          (entity, event, procedure, media, relationship, annotation, live_source, ...)
        - `graph/relationships.json` and `graph/graph.dot` — how things connect
          (render with Graphviz: `dot -Tpdf graph/graph.dot -o graph.pdf`)
        - `history/operations.jsonl` — every change ever made, oldest first, with who,
          which device, when and how (manual, capture, import, sync, AI, connector)
        - `procedures/*.md` — procedures as plain Markdown
        - `EMERGENCY.md` — emergency information, ready to print
        - `media/originals/` — your original photos, videos, audio and documents, byte-for-byte,
          named by SHA-256 so you can verify them (`shasum -a 256 <file>`)
        - `media/derived/` — thumbnails, transcripts, text recognition, AI analysis
        - `media/index.json` — metadata for every media file (dates, captions, links)
        - `live/observations.jsonl` — stored live data (weather etc.) with timestamps
        - `manifest.json` — SHA-256 of every file in this export

        Location data: \(options.stripLocation ? "REMOVED from all metadata in this export. Note: GPS embedded inside original photo files (EXIF) is only removed by exports made from the Apple app with \"Remove location\" on." : "included where recorded.")
        Restricted records (financial, identity, security...): \(options.includeRestricted ? "INCLUDED — store this export securely." : "not included (\(skipped) skipped). Export again with restricted records enabled if you need them.")
        """
    }
}

extension JSONValue {
    var objectPath: String? { if case .object(let o) = self { return o["path"]?.stringValue }; return nil }
}

public enum Markdown {
    public static func procedure(_ p: Procedure, titles: [String: String] = [:]) -> String {
        var s = "# \(p.title)\n\n"
        if p.emergency { s += "**EMERGENCY PROCEDURE**\n\n" }
        if let summary = p.summary { s += summary + "\n\n" }
        if !p.entityIDs.isEmpty { s += "Applies to: " + p.entityIDs.map { titles[$0] ?? $0 }.joined(separator: ", ") + "\n\n" }
        for (i, step) in p.steps.enumerated() { s += "\(i + 1). \(step)\n" }
        return s
    }

    public static func emergency(_ records: [RecordEnvelope], procedures: [Procedure], titles: [String: String]) -> String {
        var s = "# EMERGENCY INFORMATION\n\nPrinted from Hearth. Keep a paper copy somewhere everyone knows.\n\n"
        for p in procedures where p.emergency { s += procedure(p, titles: titles) + "\n" }
        for r in records where r.kind != .procedure {
            s += "## \(r.title)\n\n"
            if let e = try? r.decode(Entity.self) {
                if let notes = e.notes { s += notes + "\n\n" }
                for (k, v) in e.attributes.sorted(by: { $0.key < $1.key }) { s += "- **\(k)**: \(v)\n" }
                s += "\n"
            }
        }
        return s
    }
}
