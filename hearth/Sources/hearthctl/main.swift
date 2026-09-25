import Foundation
import HearthCore

// hearthctl — operate a Hearth household from a Mac, home server or NAS.
// Everything here works offline except `refresh` (live data).

let usage = """
hearthctl <command> [options]

Household
  init <store> --household NAME --owner NAME [--device NAME]
  info <store>
  add-entity <store> --kind KIND --name NAME [--notes TEXT] [--attr k=v]... [--emergency] [--sensitivity normal|private|restricted] [--category C]... [--lat L --lon L]
  add-event <store> --kind maintenance|note|repair|... --title TEXT [--body TEXT] [--entity ID] [--due-days N]
  add-procedure <store> --title TEXT --step TEXT [--step TEXT]... [--entity ID] [--emergency]
  link <store> FROM TO --type TYPE
  list <store> [KIND]
  show <store> ID
  history <store> ID
  search <store> QUERY
  due <store> [--days N]
  emergency <store>
  set <store> ID field=value [field=value]...
  delete <store> ID               (soft delete; history kept)
  purge <store> ID                (permanent: content, history values, media, derivatives)

Media
  import <store> FILE [--entity ID] [--kind photo|video|audio|document|text] [--mime TYPE] [--caption TEXT]
  media <store> [--entity ID]
  extract <store> MEDIA_ID OUT_FILE
  verify-media <store>

Live data
  add-weather <store> --name NAME --lat L --lon L [--entity ID] [--base-url URL]
  refresh <store> [--base-url URL]
  sources <store>

Sync & conflicts
  sync <store> <shared-folder>
  conflicts <store>
  resolve <store> CONFLICT_ID winner|loser|value=TEXT
  enroll <store> --identity ID --device NAME          (prints pairing code; writes enrollment.hearthpair)
  join <store> <enrollment.hearthpair> --code CODE
  revoke <store> DEVICE_ID
  add-person <store> --name NAME --role owner|adult|child|guest|emergencyAccess

Export & backup
  export <store> <out-dir> [--strip-location] [--include-restricted]
  backup <store> <out-dir>           (passphrase from $HEARTH_BACKUP_PASSPHRASE; prints recovery key)
  verify-backup <backup> [--recovery-key KEY]
  test-restore <store> <backup> [--recovery-key KEY]
  restore <backup> <new-store> [--recovery-key KEY]

Keys are kept in <store>.keys/ (override with --keys DIR or $HEARTH_KEYS), never inside the store.
"""

struct CLIError: Error, CustomStringConvertible { let description: String }

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}
func options(_ name: String) -> [String] {
    var out: [String] = []
    while let v = option(name) { out.append(v) }
    return out
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: "--\(name)") else { return false }
    args.remove(at: i); return true
}
func positional(_ what: String) throws -> String {
    guard let i = args.firstIndex(where: { !$0.hasPrefix("--") }) else { throw CLIError(description: "missing \(what)\n\n\(usage)") }
    return args.remove(at: i)
}
func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }

let keysOverride = option("keys") ?? ProcessInfo.processInfo.environment["HEARTH_KEYS"]
func keyStore(for store: URL) throws -> FileKeyStore {
    try FileKeyStore(directory: keysOverride.map(url) ?? URL(fileURLWithPath: store.path + ".keys"))
}
func openStore(_ path: String) throws -> HearthStore {
    let root = url(path)
    let store = try HearthStore.open(at: root, keyStore: keyStore(for: root))
    try? store.unlockVault() // CLI operator is trusted; on Apple this is Face ID
    return store
}
func json(_ v: some Encodable) -> String { String(decoding: try! HearthJSON.prettyEncoder.encode(v), as: UTF8.self) }
func line(_ env: RecordEnvelope) -> String {
    let flags = [env.emergency ? "EMERGENCY" : nil, env.sensitivity != .normal ? env.sensitivity.rawValue.uppercased() : nil].compactMap { $0 }
    let kindName = env.fields["kindName"]?.stringValue ?? env.fields["eventKind"]?.stringValue ?? env.fields["role"]?.stringValue ?? ""
    return "\(env.id)  \(env.kind.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(kindName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(env.title)" + (flags.isEmpty ? "" : "  [\(flags.joined(separator: ", "))]")
}
func age(_ d: Date?) -> String {
    guard let d else { return "never" }
    let s = Int(Date().timeIntervalSince(d))
    return s < 90 ? "\(s)s ago" : s < 5400 ? "\(s / 60)m ago" : s < 172800 ? "\(s / 3600)h ago" : "\(s / 86400)d ago"
}
func recoverySecret() throws -> BackupSecret {
    if let k = option("recovery-key") {
        guard let key = RecoveryKey(displayString: k) else { throw CLIError(description: "invalid recovery key") }
        return .recoveryKey(key)
    }
    guard let p = ProcessInfo.processInfo.environment["HEARTH_BACKUP_PASSPHRASE"], !p.isEmpty else {
        throw CLIError(description: "set HEARTH_BACKUP_PASSPHRASE or pass --recovery-key")
    }
    return .passphrase(p)
}

func printSources(_ store: HearthStore) throws {
    for s in try store.live.sources() {
        let readings = try store.live.readings(for: s)
        let st = try store.live.status(s.id)
        print("\(s.name) [\(s.connector)] — \(readings.first?.freshness.rawValue.uppercased() ?? "?")  last success \(age(st?.lastSuccess)), last attempt \(age(st?.lastAttempt))\(st?.lastError.map { "  error: \($0)" } ?? "")")
        for r in readings {
            guard let o = r.observation else { continue }
            let v: String = { switch o.value { case .number(let n): return String(n); case .string(let s): return s; default: return "\(o.value)" } }()
            print("   \(o.metric.padding(toLength: 22, withPad: " ", startingAt: 0)) \(v) \(o.unit ?? "")  observed \(o.observedAt)  [\(r.freshness.rawValue)]")
        }
    }
}

do {
    switch command {
    case "init":
        let root = url(try positional("store"))
        guard let household = option("household"), let owner = option("owner") else { throw CLIError(description: "--household and --owner required") }
        let store = try HearthStore.createHousehold(at: root, keyStore: keyStore(for: root), householdName: household, ownerName: owner,
                                                    deviceName: option("device") ?? ProcessInfo.processInfo.hostName, platform: "hearthctl")
        print("Created household \"\(household)\" at \(root.path)")
        print("Keys: \(try keyStore(for: root).directory.path)  (back these up via `hearthctl backup`; they are not in the store)")
        print("Owner identity: \(store.identityID)\nDevice: \(store.deviceID)")

    case "info":
        let store = try openStore(try positional("store"))
        print("Household \(store.householdID)\nDevice \(store.deviceID)\nIdentity \(try store.currentIdentity().displayName) (\(try store.currentIdentity().role.rawValue))")
        for (k, v) in try store.stats().sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }
        for b in try BackupManager.log(store) {
            print("  backup \(b.createdAt) \(b.verifiedByTestRestore != nil ? "VERIFIED by test restore" : "NOT YET VERIFIED") \(b.location)")
        }

    case "add-person":
        let store = try openStore(try positional("store"))
        guard let name = option("name"), let role = option("role").flatMap(HouseholdRole.init) else { throw CLIError(description: "--name and --role required") }
        let p = Identity(displayName: name, role: role)
        try store.save(p)
        print(p.id)

    case "add-entity":
        let store = try openStore(try positional("store"))
        guard let kind = option("kind"), let name = option("name") else { throw CLIError(description: "--kind and --name required") }
        var attrs: [String: String] = [:]
        for a in options("attr") { let p = a.split(separator: "=", maxSplits: 1).map(String.init); if p.count == 2 { attrs[p[0]] = p[1] } }
        let loc: GeoPoint? = { if let la = option("lat").flatMap(Double.init), let lo = option("lon").flatMap(Double.init) { return GeoPoint(latitude: la, longitude: lo) }; return nil }()
        let e = Entity(kindName: kind, name: name, notes: option("notes"), attributes: attrs, location: loc,
                       sensitivity: option("sensitivity").flatMap(Sensitivity.init) ?? .normal,
                       categories: options("category").compactMap(SensitiveCategory.init), emergency: flag("emergency"))
        try store.save(e)
        print(e.id)

    case "add-event":
        let store = try openStore(try positional("store"))
        guard let title = option("title") else { throw CLIError(description: "--title required") }
        let due = option("due-days").flatMap(Double.init).map { Date().addingTimeInterval($0 * 86400) }
        let ev = HouseholdEvent(eventKind: option("kind").flatMap(EventKind.init) ?? .note, title: title, body: option("body"),
                                entityIDs: options("entity"), dueAt: due)
        try store.save(ev)
        print(ev.id)

    case "add-procedure":
        let store = try openStore(try positional("store"))
        guard let title = option("title") else { throw CLIError(description: "--title required") }
        let p = Procedure(title: title, summary: option("summary"), steps: options("step"), entityIDs: options("entity"), emergency: flag("emergency"))
        try store.save(p)
        print(p.id)

    case "link":
        let store = try openStore(try positional("store"))
        let type = option("type") ?? Relationship.attachedTo
        let from = try positional("FROM"), to = try positional("TO")
        print(try store.link(from, to: to, type: type).id)

    case "list":
        let store = try openStore(try positional("store"))
        let kind = args.first.map { RecordKind(rawValue: $0) }
        for env in try store.allEnvelopes(kind: kind) { print(line(env)) }
        let locked = try store.lockedCount(kind: kind)
        if locked > 0 { print("(\(locked) restricted record(s) locked)") }

    case "show":
        let store = try openStore(try positional("store"))
        let id = try positional("ID")
        guard let env = try store.envelope(id) else { throw CLIError(description: "not found") }
        print(json(JSONValue.object(env.fields)))
        for r in try store.relationships(of: id) {
            let other = r.from == id ? r.to : r.from
            print("  \(r.from == id ? "→" : "←") \(r.type) \((try? store.envelope(other))??.title ?? other) (\(other))")
        }

    case "history":
        let store = try openStore(try positional("store"))
        for h in try store.history(of: try positional("ID")) {
            let vals = h.redacted ? "<purged>" : h.values.map { String(decoding: try! HearthJSON.encoder.encode($0), as: UTF8.self) } ?? "<locked>"
            print("\(h.at.date)  \(h.action.rawValue)  device=\(h.device.prefix(8))  via=\(h.provenance.method.rawValue)  \(vals)")
        }

    case "search":
        let store = try openStore(try positional("store"))
        for hit in try store.search(args.joined(separator: " ")) { print(line(hit.record)) }

    case "due":
        let store = try openStore(try positional("store"))
        let days = option("days").flatMap(Double.init) ?? 7
        for e in try store.dueEvents(within: days * 86400) { print("\(e.dueAt!)  \(e.title)  (\(e.id))") }

    case "emergency":
        let store = try openStore(try positional("store"))
        let recs = try store.emergencyRecords()
        let titles = Dictionary(uniqueKeysWithValues: try store.allEnvelopes(kind: nil).map { ($0.id, $0.title) })
        print(Markdown.emergency(recs, procedures: recs.compactMap { try? $0.decode(Procedure.self) }, titles: titles))

    case "set":
        let store = try openStore(try positional("store"))
        let id = try positional("ID")
        var fields: [String: JSONValue] = [:]
        for a in args { let p = a.split(separator: "=", maxSplits: 1).map(String.init); if p.count == 2 { fields[p[0]] = .string(p[1]) } }
        try store.update(id, fields: fields)
        print("Updated \(fields.keys.sorted().joined(separator: ", "))")

    case "delete":
        let store = try openStore(try positional("store"))
        try store.delete(try positional("ID"))
        print("Deleted (history kept). Use `purge` to remove permanently.")

    case "purge":
        let store = try openStore(try positional("store"))
        let report = try store.purge(try positional("ID"))
        print(report.explanation)
        for b in report.backupsThatMayStillContainData { print("  backup \(b.createdAt) at \(b.location)") }

    case "import":
        let store = try openStore(try positional("store"))
        let file = url(try positional("FILE"))
        let ext = file.pathExtension.lowercased()
        let guessedKind: MediaKind = ["mov", "mp4", "m4v"].contains(ext) ? .video : ["m4a", "mp3", "wav", "caf"].contains(ext) ? .audio
            : ["pdf"].contains(ext) ? .document : ["txt", "md"].contains(ext) ? .text : .photo
        let mime = option("mime") ?? ["jpg": "image/jpeg", "jpeg": "image/jpeg", "heic": "image/heic", "png": "image/png", "mov": "video/quicktime",
                                     "mp4": "video/mp4", "m4a": "audio/mp4", "pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown"][ext] ?? "application/octet-stream"
        let created = (try? FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date) ?? nil
        let m = try store.media.importOriginal(file: file, kind: option("kind").flatMap(MediaKind.init) ?? guessedKind, mimeType: mime,
                                               capturedAt: created, caption: option("caption"), attachTo: option("entity"))
        print("\(m.id)  sha256=\(m.sha256)  \(m.byteCount) bytes")

    case "media":
        let store = try openStore(try positional("store"))
        let list = try option("entity").map { try store.media.media(attachedTo: $0) } ?? store.media.all()
        for m in list {
            print("\(m.id)  \(m.role.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(m.mediaKind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(m.byteCount) B  \(m.originalFilename ?? "")  local=\(store.media.hasLocalBlob(m))")
        }

    case "extract":
        let store = try openStore(try positional("store"))
        let id = try positional("MEDIA_ID"), out = url(try positional("OUT_FILE"))
        guard let m = try store.fetch(MediaObject.self, id: id) else { throw CLIError(description: "not found") }
        try store.media.decrypt(m, to: out)
        print("Wrote \(out.path) (sha256 verified)")

    case "verify-media":
        let store = try openStore(try positional("store"))
        let r = try store.media.verifyAll()
        print("checked \(r.checked); missing \(r.missing.count); corrupt \(r.corrupt.count) — \(r.ok ? "OK" : "PROBLEMS")")

    case "add-weather":
        let store = try openStore(try positional("store"))
        guard let name = option("name"), let lat = option("lat").flatMap(Double.init), let lon = option("lon").flatMap(Double.init) else {
            throw CLIError(description: "--name --lat --lon required")
        }
        let source = OpenMeteoConnector.makeSource(name: name, location: GeoPoint(latitude: lat, longitude: lon), entityID: option("entity"))
        try store.save(source)
        print(source.id)
        print(OpenMeteoConnector().disclosure(for: source))

    case "refresh":
        let store = try openStore(try positional("store"))
        if let base = option("base-url").flatMap(URL.init(string:)) { store.live.register(OpenMeteoConnector(baseURL: base)) }
        for s in try store.live.sources() {
            let outcome = await store.live.refresh(s)
            print("\(s.name): \(outcome)")
        }
        try printSources(store)

    case "sources":
        try printSources(try openStore(try positional("store")))

    case "sync":
        let store = try openStore(try positional("store"))
        let transport = try DirectorySyncTransport(folder: url(try positional("shared-folder")))
        print(try store.sync(with: transport))
        let c = try store.conflicts()
        if !c.isEmpty { print("\(c.count) unresolved conflict(s) — see `hearthctl conflicts`") }

    case "conflicts":
        let store = try openStore(try positional("store"))
        for c in try store.conflicts() {
            let title = (try? store.envelope(c.recordID))??.title ?? c.recordID
            print("\(c.id)  \(title).\(c.field)\n    kept:  \(c.winningValue.map { json($0) } ?? "?") (device \(c.winningDevice?.prefix(8) ?? "?"))\n    other: \(c.losingValue.map { json($0) } ?? "?") (device \(c.losingDevice?.prefix(8) ?? "?"))")
        }

    case "resolve":
        let store = try openStore(try positional("store"))
        let id = try positional("CONFLICT_ID"), choice = try positional("choice")
        guard let c = try store.conflicts().first(where: { $0.id == id }) else { throw CLIError(description: "no such open conflict") }
        let res: HearthStore.Resolution = choice == "winner" ? .keepWinner : choice == "loser" ? .takeLoser
            : .custom(.string(String(choice.dropFirst("value=".count))))
        try store.resolve(c, with: res)
        print("Resolved; both original values remain in history.")

    case "enroll":
        let store = try openStore(try positional("store"))
        guard let identity = option("identity"), let name = option("device") else { throw CLIError(description: "--identity and --device required") }
        let code = PairingCode.generate()
        let sealed = try store.enrollDevice(name: name, platform: option("platform") ?? "unknown", for: identity, pairingCode: code)
        let out = url(option("out") ?? "enrollment.hearthpair")
        try HearthJSON.encoder.encode(sealed).write(to: out)
        print("Wrote \(out.path). Pairing code (tell it to the new device, don't send it with the file):\n\n    \(code)\n")

    case "join":
        let root = url(try positional("store"))
        let file = url(try positional("enrollment"))
        guard let code = option("code") else { throw CLIError(description: "--code required") }
        let sealed = try HearthJSON.decoder.decode(SealedEnrollment.self, from: Data(contentsOf: file))
        let store = try HearthStore.joinHousehold(at: root, keyStore: keyStore(for: root), enrollment: HearthStore.openEnrollment(sealed, pairingCode: code))
        print("Joined household \(store.householdID) as device \(store.deviceID). Run `hearthctl sync` to receive data.")

    case "revoke":
        let store = try openStore(try positional("store"))
        try store.revokeDevice(try positional("DEVICE_ID"))
        print("Revoked. Changes it makes from now on will be rejected by every device after they sync. Rotate the household key by re-creating backups and re-enrolling remaining devices if the device may be compromised.")

    case "export":
        let store = try openStore(try positional("store"))
        let out = url(try positional("out-dir"))
        let r = try Exporter.export(store, to: out, options: .init(includeRestricted: flag("include-restricted"), stripLocation: flag("strip-location")))
        print("Exported \(r.recordCount) records, \(r.mediaCount) media files, \(r.fileCount) files to \(r.directory.path)")
        if r.skippedRestricted > 0 { print("(\(r.skippedRestricted) restricted records not included; use --include-restricted)") }

    case "backup":
        let store = try openStore(try positional("store"))
        let out = url(try positional("out-dir"))
        guard let pass = ProcessInfo.processInfo.environment["HEARTH_BACKUP_PASSPHRASE"], pass.count >= 8 else {
            throw CLIError(description: "set HEARTH_BACKUP_PASSPHRASE (8+ characters)")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let recovery = RecoveryKey.generate()
        let r = try BackupManager.createBackup(of: store, to: out, passphrase: pass, recoveryKey: recovery)
        print("Backup written: \(r.location.path) (\(r.fileCount) files, \(r.totalBytes) bytes)")
        print("\nRECOVERY KEY — write this down and keep it somewhere safe. It is not stored anywhere:\n\n    \(recovery.displayString)\n")
        print("This backup is NOT verified until you run: hearthctl test-restore \(CommandLine.arguments[2]) \(r.location.path)")

    case "verify-backup":
        let dir = url(try positional("backup"))
        print(try BackupManager.verify(dir, secret: recoverySecret()))

    case "test-restore":
        let store = try openStore(try positional("store"))
        let dir = url(try positional("backup"))
        let r = try BackupManager.testRestore(dir, secret: recoverySecret(), recordingIn: store)
        print(r)
        if !r.ok { exit(2) }

    case "restore":
        let dir = url(try positional("backup")), root = url(try positional("new-store"))
        let store = try BackupManager.restore(dir, secret: recoverySecret(), into: root, keyStore: keyStore(for: root))
        print("Restored household \(store.householdID) to \(root.path); keys written to \(try keyStore(for: root).directory.path)")
        for (k, v) in try store.stats().sorted(by: { $0.key < $1.key }) { print("  \(k): \(v)") }

    case "help", "--help", "-h":
        print(usage)

    default:
        throw CLIError(description: "unknown command \(command)\n\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
