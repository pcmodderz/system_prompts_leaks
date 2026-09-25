import HearthCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var addingEntity = false

    var body: some View {
        NavigationStack {
            List {
                if !model.isOnline {
                    Label("Offline — everything stored on this device is available. Changes will sync later.", systemImage: "wifi.slash")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !model.inbox.isEmpty {
                    Section("Shared to Hearth") {
                        NavigationLink { InboxView() } label: {
                            Label("\(model.inbox.count) item(s) to file", systemImage: "tray.and.arrow.down")
                        }
                    }
                }
                if !model.conflicts.isEmpty {
                    Section {
                        NavigationLink { ConflictsView() } label: {
                            Label("\(model.conflicts.count) edit(s) need a decision", systemImage: "arrow.triangle.branch").foregroundStyle(.orange)
                        }
                    }
                }
                if !model.liveReadings.isEmpty {
                    Section("House state") {
                        ForEach(model.liveReadings.filter { ["temperature_2m", "relative_humidity_2m", "wind_speed_10m"].contains($0.observation?.metric ?? "") || $0.observation == nil },
                                id: \.self.rowID) { LiveReadingRow(reading: $0) }
                    }
                }
                Section("Due this week") {
                    if model.due.isEmpty { Text("Nothing due").foregroundStyle(.secondary) }
                    ForEach(model.due, id: \.id) { e in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(e.title)
                                if let d = e.dueAt { Text(d, style: .date).font(.caption).foregroundStyle(d < Date() ? Color.red : Color.secondary) }
                            }
                            Spacer()
                            Button("Done") { var done = e; done.completedAt = Date(); model.save(done) }.buttonStyle(.bordered)
                        }
                    }
                }
                if !model.recentMedia.isEmpty {
                    Section("Recent captures") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack {
                                ForEach(model.recentMedia, id: \.id) { m in
                                    NavigationLink { MediaViewer(media: m) } label: {
                                        MediaThumbnail(media: m).frame(width: 88, height: 88).clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                        }
                        .frame(height: 92)
                    }
                }
                Section("Household") {
                    ForEach(groupedKinds, id: \.self) { kind in
                        NavigationLink { EntityListView(kindName: kind) } label: {
                            HStack { Text(kind.capitalized); Spacer(); Text("\(model.entities.filter { $0.kindName == kind }.count)").foregroundStyle(.secondary) }
                        }
                    }
                    NavigationLink { EntityListView(kindName: nil) } label: { Text("Everything") }
                    NavigationLink { ProceduresView() } label: { Text("Procedures") }
                    if model.lockedCount > 0 || model.vaultUnlocked {
                        NavigationLink { VaultGate { EntityListView(kindName: nil, restrictedOnly: true) } } label: {
                            Label("Protected records", systemImage: model.vaultUnlocked ? "lock.open" : "lock")
                        }
                    }
                }
            }
            .navigationTitle("Hearth")
            .refreshable { await model.refreshLive(); model.syncIfConfigured() }
            .toolbar {
                Button { addingEntity = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $addingEntity) { EntityEditor(entity: nil) }
        }
    }

    var groupedKinds: [String] { Array(Set(model.entities.map(\.kindName))).sorted() }
}

extension LiveReading {
    var rowID: String { source.id + (observation?.metric ?? "") }
}

struct InboxView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: [String: String] = [:]

    var body: some View {
        List {
            Text("These were shared into Hearth from other apps. Choose what each belongs to.").font(.callout).foregroundStyle(.secondary)
            ForEach(model.inbox, id: \.file) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.metadata.filename).font(.headline)
                    if let t = item.metadata.sharedText { Text(t).font(.caption) }
                    if let u = item.metadata.sharedURL { Text(u).font(.caption).foregroundStyle(.blue) }
                    Picker("Belongs to", selection: Binding(get: { selection[item.file.path] ?? "" }, set: { selection[item.file.path] = $0 })) {
                        Text("Nothing yet").tag("")
                        ForEach(model.entities, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Button("File it") { model.file(item, to: selection[item.file.path].flatMap { $0.isEmpty ? nil : $0 }) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Inbox")
    }
}

struct ConflictsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List(model.conflicts) { c in
            VStack(alignment: .leading, spacing: 8) {
                Text("\((try? model.store?.envelope(c.recordID))?.title ?? c.recordID) — \(c.field)").font(.headline)
                Text("Two people changed this at the same time. Both versions are kept in history.").font(.caption).foregroundStyle(.secondary)
                Button { model.resolve(c, .keepWinner) } label: { Text("Keep: \(Self.show(c.winningValue))") }
                Button { model.resolve(c, .takeLoser) } label: { Text("Use: \(Self.show(c.losingValue))") }
            }
        }
        .navigationTitle("Needs a decision")
    }

    static func show(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .bool(let b): return b ? "Yes" : "No"
        case .none, .null: return "(empty)"
        default: return "(changed)"
        }
    }
}
