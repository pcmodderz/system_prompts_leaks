import HearthCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Your data") {
                    NavigationLink("Backup & restore") { BackupView() }
                    NavigationLink("Export everything") { ExportView() }
                    NavigationLink("Where your data lives") { SovereigntyView() }
                }
                Section("Household") {
                    NavigationLink("People & devices") { DevicesView() }
                    NavigationLink("Sync") { SyncSettingsView() }
                    NavigationLink("Live data sources") { SourcesView() }
                }
                Section("Protection") {
                    if model.vaultUnlocked {
                        Button("Lock protected records") { model.lockVault() }
                    } else {
                        Button("Unlock protected records") { Task { await model.unlockVault() } }
                    }
                    Text("Protected records lock automatically when Hearth leaves the screen.").font(.caption).foregroundStyle(.secondary)
                }
                Section("AI") {
                    NavigationLink("AI models & privacy") { AISettingsView() }
                }
                Section("Privacy") {
                    LabeledContent("Analytics", value: "None")
                    Text("Hearth contains no analytics or tracking SDKs and sends no telemetry. Nothing about your household leaves your devices unless you configure sync, a live data source or an AI model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct SovereigntyView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            Section("On this device") {
                LabeledContent("Database", value: "Encrypted (AES-256-GCM)")
                LabeledContent("Media", value: "Encrypted, content-addressed")
                LabeledContent("Keys", value: "Keychain, this device only")
                LabeledContent("Protected records", value: "Secure Enclave + Face ID")
                if let s = try? model.store?.stats() {
                    LabeledContent("Records", value: "\(s.filter { !$0.key.hasPrefix("_") }.values.reduce(0, +))")
                    LabeledContent("Media files", value: "\(s["_blobs"] ?? 0)")
                    LabeledContent("History entries", value: "\(s["_ops"] ?? 0)")
                }
            }
            Section("Leaves this device only if you set it up") {
                LabeledContent("Sync", value: SyncFolder.displayName ?? "Off")
                LabeledContent("Live data", value: "\(Set(model.liveReadings.map(\.source.id)).count) source(s)")
                LabeledContent("External AI", value: AISettingsStore.load().externalAIEnabled ? "On (asks first)" : "Off")
            }
            Section {
                Text("If Hearth's makers disappeared tomorrow, your household would still have everything: an export in open formats (JSON, Markdown, original files) and encrypted backups that only your passphrase or recovery key can open.")
            }
        }
        .navigationTitle("Where your data lives")
    }
}

struct BackupView: View {
    @EnvironmentObject var model: AppModel
    @State private var passphrase = ""
    @State private var choosingFolder = false
    @State private var recovery: RecoveryKey?
    @State private var status: String?
    @State private var working = false
    @State private var log: [BackupManager.BackupLogEntry] = []
    @State private var lastBackup: URL?

    var body: some View {
        Form {
            Section {
                SecureField("Backup passphrase (12+ characters)", text: $passphrase)
                Button("Back up to a folder…") { choosingFolder = true }.disabled(passphrase.count < 12 || working)
            } footer: {
                Text("Choose any folder: an external drive, a NAS in Files, or a cloud folder you control. The backup is encrypted; only your passphrase or recovery key can open it.")
            }
            if let recovery {
                Section("Recovery key — write this down") {
                    Text(recovery.displayString).font(.title3.monospaced()).textSelection(.enabled)
                    Text("Nobody else has this key, including Hearth. Keep it with your important papers.").font(.caption)
                }
            }
            if let lastBackup {
                Section {
                    Button("Test restore now") { Task { await testRestore(lastBackup) } }
                } footer: { Text("A backup isn't verified until it has been restored successfully. This restores into a temporary space and checks every record and file.") }
            }
            if let status { Section { Text(status) } }
            Section("Backups") {
                ForEach(log, id: \.id) { b in
                    VStack(alignment: .leading) {
                        Text(b.createdAt.formatted())
                        Label(b.verifiedByTestRestore != nil ? "Verified by test restore" : "Not verified yet",
                              systemImage: b.verifiedByTestRestore != nil ? "checkmark.seal.fill" : "exclamationmark.circle")
                            .font(.caption).foregroundStyle(b.verifiedByTestRestore != nil ? .green : .orange)
                    }
                }
            }
        }
        .navigationTitle("Backup")
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await backup(to: url) } }
        }
        .task { log = (try? model.store.map(BackupManager.log)) ?? [] }
    }

    func backup(to folder: URL) async {
        guard let store = model.store else { return }
        working = true; defer { working = false }
        if !model.vaultUnlocked { await model.unlockVault() } // include protected records
        let key = RecoveryKey.generate()
        let pass = passphrase
        do {
            let receipt = try await Task.detached {
                guard folder.startAccessingSecurityScopedResource() else { throw CocoaError(.fileWriteNoPermission) }
                defer { folder.stopAccessingSecurityScopedResource() }
                return try BackupManager.createBackup(of: store, to: folder, passphrase: pass, recoveryKey: key)
            }.value
            recovery = key
            lastBackup = receipt.location
            status = "Backup written (\(ByteCountFormatter.string(fromByteCount: receipt.totalBytes, countStyle: .file)))."
            log = try BackupManager.log(store)
        } catch {
            status = "Backup failed: \(error.localizedDescription)"
        }
    }

    func testRestore(_ location: URL) async {
        guard let store = model.store else { return }
        let pass = passphrase
        status = "Testing restore…"
        let result = await Task.detached { () -> String in
            let parent = location.deletingLastPathComponent()
            _ = parent.startAccessingSecurityScopedResource()
            defer { parent.stopAccessingSecurityScopedResource() }
            do { return try BackupManager.testRestore(location, secret: .passphrase(pass), recordingIn: store).description }
            catch { return "Test restore failed: \(error)" }
        }.value
        status = result
        log = (try? BackupManager.log(store)) ?? []
    }
}

struct RestoreView: View {
    @EnvironmentObject var model: AppModel
    @State private var choosing = false
    @State private var backup: URL?
    @State private var secret = ""
    @State private var status: String?

    var body: some View {
        Form {
            Button(backup?.lastPathComponent ?? "Choose backup folder…") { choosing = true }
            SecureField("Passphrase or recovery key", text: $secret)
            Button("Restore") { restore() }.disabled(backup == nil || secret.isEmpty)
            if let status { Text(status) }
        }
        .navigationTitle("Restore")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .item]) { if case .success(let u) = $0 { backup = u } }
    }

    func restore() {
        guard let backup else { return }
        let s: BackupSecret = RecoveryKey(displayString: secret).map { .recoveryKey($0) } ?? .passphrase(secret)
        do {
            _ = backup.startAccessingSecurityScopedResource()
            defer { backup.stopAccessingSecurityScopedResource() }
            let store = try BackupManager.restore(backup, secret: s, into: AppPaths.storeRoot, keyStore: model.runtime.keyStore)
            model.runtime.adopt(store)
            model.phase = .ready
            model.reload()
        } catch {
            status = "Couldn't restore: \(error.localizedDescription)"
        }
    }
}

struct ExportView: View {
    @EnvironmentObject var model: AppModel
    @State private var stripLocation = true
    @State private var includeRestricted = false
    @State private var exported: URL?
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                Toggle("Remove location information", isOn: $stripLocation)
                Toggle("Include protected records", isOn: $includeRestricted)
                Button("Create export") { Task { await export() } }
            } footer: {
                Text("Creates a folder of plain JSON, Markdown and your original files with checksums — usable without Hearth.")
            }
            if let status { Text(status) }
            if let exported { ShareLink(item: exported) { Label("Save or share export", systemImage: "square.and.arrow.up") } }
        }
        .navigationTitle("Export")
    }

    func export() async {
        guard let store = model.store else { return }
        if includeRestricted && !model.vaultUnlocked { await model.unlockVault(); guard model.vaultUnlocked else { return } }
        let opts = Exporter.Options(includeRestricted: includeRestricted, stripLocation: stripLocation)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("exports")
        do {
            let r = try await Task.detached { try Exporter.export(store, to: out, options: opts) }.value
            status = "\(r.recordCount) records, \(r.mediaCount) media files."
            exported = r.directory
        } catch { status = error.localizedDescription }
    }
}

struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var people: [Identity] = []
    @State private var devices: [DeviceRecord] = []
    @State private var addingPerson = false
    @State private var newName = ""
    @State private var newRole: HouseholdRole = .adult
    @State private var enrollment: (url: URL, code: String)?

    var body: some View {
        List {
            Section("People") {
                ForEach(people, id: \.id) { p in
                    HStack {
                        Text(p.displayName); Spacer(); Text(p.role.rawValue).foregroundStyle(.secondary)
                        Menu {
                            Button("Add a device for \(p.displayName)") { enroll(p) }
                            Button("Use this device as \(p.displayName)") { try? model.store?.switchIdentity(to: p.id); model.reload() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
                Button("Add person") { addingPerson = true }
            }
            Section("Trusted devices") {
                ForEach(devices, id: \.id) { d in
                    VStack(alignment: .leading) {
                        Text(d.name + (d.id == model.store?.deviceID ? " (this device)" : ""))
                        Text(d.revokedAt == nil ? d.platform : "Removed \(d.revokedAt!.date.formatted())").font(.caption).foregroundStyle(d.revokedAt == nil ? Color.secondary : Color.red)
                    }
                    .swipeActions {
                        if d.revokedAt == nil && d.id != model.store?.deviceID {
                            Button("Remove", role: .destructive) { try? model.store?.revokeDevice(d.id); load() }
                        }
                    }
                }
            }
            if let enrollment {
                Section("Pair the new device") {
                    Text("On the new device choose \"Join from another household device\", open this file, and type:")
                    Text(enrollment.code).font(.title.monospaced()).textSelection(.enabled)
                    ShareLink(item: enrollment.url) { Label("Send pairing file (AirDrop)", systemImage: "square.and.arrow.up") }
                    Text("Send the code separately (say it out loud). The file is useless without it.").font(.caption)
                }
            }
        }
        .navigationTitle("People & devices")
        .task { load() }
        .alert("Add person", isPresented: $addingPerson) {
            TextField("Name", text: $newName)
            Button("Adult") { add(.adult) }
            Button("Child") { add(.child) }
            Button("Guest") { add(.guest) }
            Button("Emergency access") { add(.emergencyAccess) }
            Button("Cancel", role: .cancel) {}
        }
    }

    func load() {
        people = (try? model.store?.all(Identity.self)) ?? []
        devices = (try? model.store?.all(DeviceRecord.self)) ?? []
    }

    func add(_ role: HouseholdRole) {
        guard !newName.isEmpty else { return }
        model.save(Identity(displayName: newName, role: role)); newName = ""; load()
    }

    func enroll(_ person: Identity) {
        Task {
            if person.role == .owner || person.role == .adult { await model.unlockVault() }
            guard let store = model.store else { return }
            let code = PairingCode.generate()
            do {
                let sealed = try store.enrollDevice(name: "\(person.displayName)'s device", platform: "iOS", for: person.id, pairingCode: code)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Join Hearth.hearthpair")
                try HearthJSON.encoder.encode(sealed).write(to: url)
                enrollment = (url, code)
                load()
            } catch { model.lastError = error.localizedDescription }
        }
    }
}

struct JoinHouseholdView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var file: URL?
    @State private var choosing = false
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Button(file?.lastPathComponent ?? "Choose pairing file…") { choosing = true }
                TextField("Pairing code", text: $code).textInputAutocapitalization(.characters).font(.body.monospaced())
                Button("Join") {
                    guard let file, let data = try? Data(contentsOf: file),
                          let sealed = try? HearthJSON.decoder.decode(SealedEnrollment.self, from: data) else { return }
                    model.joinHousehold(sealed: sealed, code: code); dismiss()
                }.disabled(file == nil || code.count < 12)
                Text("After joining, choose the household's sync folder in Settings → Sync to receive its records and media.").font(.caption)
            }
            .navigationTitle("Join household")
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item]) { if case .success(let u) = $0 { _ = u.startAccessingSecurityScopedResource(); file = u } }
        }
    }
}

struct SyncSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var choosing = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Sync folder", value: SyncFolder.displayName ?? "None")
                Button("Choose folder…") { choosing = true }
                if SyncFolder.displayName != nil {
                    Button("Sync now") { model.syncIfConfigured() }
                    Button("Stop syncing", role: .destructive) { SyncFolder.clear() }
                }
            } footer: {
                Text("Sync is optional. Pick a folder your household controls — a NAS share in Files, a Syncthing folder, an external drive, or a cloud folder you choose. Everything written there is encrypted. Your devices keep their own complete copies; the folder only relays changes.")
            }
            if let r = model.lastSync { Section("Last sync") { Text(r.description).font(.caption) } }
        }
        .navigationTitle("Sync")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) {
            if case .success(let url) = $0 { try? SyncFolder.save(url); model.syncIfConfigured() }
        }
    }
}

struct SourcesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            ForEach(Dictionary(grouping: model.liveReadings, by: \.source.id).values.map { $0 }, id: \.first!.source.id) { readings in
                Section(readings[0].source.name) {
                    if let e = readings[0].lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                    Text(OpenMeteoConnector().disclosure(for: readings[0].source)).font(.caption).foregroundStyle(.secondary)
                    ForEach(readings, id: \.rowID) { LiveReadingRow(reading: $0) }
                }
            }
            Text("Live values are stored locally with their history. If a source can't be reached, Hearth keeps showing the last value marked OFFLINE or STALE. iOS decides when background refresh runs, so values show when they were last updated.")
                .font(.caption)
        }
        .navigationTitle("Live data")
        .refreshable { await model.refreshLive() }
    }
}

enum AISettingsStore {
    static let key = "hearth.aiSettings"
    static func load() -> AIPolicySettings {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode(AIPolicySettings.self, from: $0) } ?? AIPolicySettings()
    }
    static func save(_ s: AIPolicySettings) { UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: key) }
}

struct AISettingsView: View {
    @State private var settings = AISettingsStore.load()
    var body: some View {
        Form {
            Section("Household models") {
                Text("Point Hearth at a model running on your Mac or home server (any OpenAI-compatible endpoint such as Ollama or LM Studio). Data stays in your home.")
                    .font(.caption)
            }
            Section("External providers") {
                Toggle("Allow external AI", isOn: $settings.externalAIEnabled)
                Toggle("Allow photos/video to external AI", isOn: $settings.allowMediaExternally).disabled(!settings.externalAIEnabled)
                Text("Protected records are never sent to external providers. Before anything leaves, Hearth shows what, why, where and to whom, and you choose Allow once, Allow for this source, or Deny.")
                    .font(.caption)
            }
            Section { Text("Hearth works fully without AI. Emergency information never requires AI.").font(.caption) }
        }
        .navigationTitle("AI")
        .onChange(of: settings.externalAIEnabled) { _, _ in AISettingsStore.save(settings) }
        .onChange(of: settings.allowMediaExternally) { _, _ in AISettingsStore.save(settings) }
    }
}
