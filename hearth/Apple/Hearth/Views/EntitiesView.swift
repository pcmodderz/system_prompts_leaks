import HearthCore
import SwiftUI

struct EntityListView: View {
    @EnvironmentObject var model: AppModel
    let kindName: String?
    var restrictedOnly = false

    var items: [Entity] {
        model.entities.filter { (kindName == nil || $0.kindName == kindName) && (!restrictedOnly || $0.sensitivity == .restricted) }
    }

    var body: some View {
        List(items, id: \.id) { e in
            NavigationLink { EntityDetailView(entityID: e.id) } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(e.name)
                        Text(e.kindName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.emergency { Image(systemName: "cross.case.fill").foregroundStyle(.red) }
                    if e.sensitivity == .restricted { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle(kindName?.capitalized ?? (restrictedOnly ? "Protected" : "Everything"))
        .overlay { if items.isEmpty { ContentUnavailableView("Nothing here yet", systemImage: "house") } }
    }
}

struct EntityDetailView: View {
    @EnvironmentObject var model: AppModel
    let entityID: String
    @State private var editing = false
    @State private var addingEvent = false
    @State private var history: [HistoryEntry] = []

    var entity: Entity? { try? model.store?.fetch(Entity.self, id: entityID) }
    var media: [MediaObject] { (try? model.store?.media.media(attachedTo: entityID)) ?? [] }
    var events: [HouseholdEvent] { ((try? model.store?.all(HouseholdEvent.self)) ?? []).filter { $0.entityIDs.contains(entityID) }.sorted { $0.occurredAt > $1.occurredAt } }
    var procedures: [Procedure] { model.procedures.filter { $0.entityIDs.contains(entityID) } }
    var sources: [LiveReading] { model.liveReadings.filter { $0.source.entityID == entityID } }

    var body: some View {
        if let entity {
            List {
                Section {
                    if let notes = entity.notes { Text(notes) }
                    ForEach(entity.attributes.sorted(by: { $0.key < $1.key }), id: \.key) { LabeledContent($0.key, value: $0.value) }
                    if entity.location != nil { Label("Location recorded", systemImage: "mappin").font(.caption) }
                }
                if !sources.isEmpty {
                    Section("Live") { ForEach(sources, id: \.rowID) { LiveReadingRow(reading: $0) } }
                }
                if !procedures.isEmpty {
                    Section("Procedures") {
                        ForEach(procedures, id: \.id) { p in NavigationLink(p.title) { ProcedureView(procedure: p) } }
                    }
                }
                Section("Photos, video & documents") {
                    if media.isEmpty {
                        Text("Use Capture to add photos, video, scans or audio.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 6) {
                            ForEach(media, id: \.id) { m in
                                NavigationLink { MediaViewer(media: m) } label: {
                                    MediaThumbnail(media: m).frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }
                    NavigationLink("Capture for \(entity.name)") { CaptureView(attachTo: entityID) }
                }
                Section("Timeline") {
                    Button("Add maintenance or note") { addingEvent = true }
                    ForEach(events, id: \.id) { e in
                        VStack(alignment: .leading) {
                            Text(e.title)
                            Text("\(e.eventKind.rawValue) · \(e.occurredAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("History") {
                    DisclosureGroup("\(history.count) change(s)") {
                        ForEach(history, id: \.opID) { h in
                            VStack(alignment: .leading) {
                                Text(h.at.date.formatted()).font(.caption)
                                Text(h.redacted ? "Permanently deleted" : (h.values?.keys.sorted().joined(separator: ", ") ?? "Protected")).font(.caption2).foregroundStyle(.secondary)
                                Text("via \(h.provenance.method.rawValue)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if entity.kindName == "home" && sources.isEmpty {
                    Button("Add weather for this home") { model.addWeatherSource(for: entity) }
                }
            }
            .navigationTitle(entity.name)
            .toolbar { Button("Edit") { editing = true } }
            .sheet(isPresented: $editing) { EntityEditor(entity: entity) }
            .sheet(isPresented: $addingEvent) { EventEditor(entityID: entityID) }
            .task { history = (try? model.store?.history(of: entityID)) ?? [] }
        } else {
            ContentUnavailableView("Not available", systemImage: "questionmark")
        }
    }
}

struct EntityEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @StateObject private var location = LocationProvider()
    let entity: Entity?
    @State private var name = ""
    @State private var kind = "appliance"
    @State private var notes = ""
    @State private var attributes: [(String, String)] = []
    @State private var sensitivity: Sensitivity = .normal
    @State private var categories: Set<SensitiveCategory> = []
    @State private var emergency = false
    @State private var point: GeoPoint?

    static let kinds = ["home", "room", "appliance", "system", "utility", "vehicle", "pet", "person", "account", "document", "network", "equipment", "other"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) { ForEach(Self.kinds, id: \.self) { Text($0.capitalized) } }
                TextField("Notes", text: $notes, axis: .vertical)
                Section("Details") {
                    ForEach(attributes.indices, id: \.self) { i in
                        HStack {
                            TextField("Label", text: Binding(get: { attributes[i].0 }, set: { attributes[i].0 = $0 }))
                            TextField("Value", text: Binding(get: { attributes[i].1 }, set: { attributes[i].1 = $0 }))
                        }
                    }
                    Button("Add detail") { attributes.append(("", "")) }
                }
                Section("Protection") {
                    Toggle("Emergency information", isOn: $emergency)
                    Picker("Sensitivity", selection: $sensitivity) {
                        Text("Household").tag(Sensitivity.normal)
                        Text("Private").tag(Sensitivity.private)
                        Text("Protected (Face ID)").tag(Sensitivity.restricted)
                    }
                    ForEach([SensitiveCategory.financial, .identity, .insurance, .medical, .security, .network], id: \.self) { c in
                        Toggle(c.rawValue.capitalized, isOn: Binding(get: { categories.contains(c) }, set: { if $0 { categories.insert(c) } else { categories.remove(c) } }))
                    }
                }
                Section("Location (private)") {
                    if point != nil {
                        Label("Location recorded", systemImage: "mappin")
                        Button("Remove location", role: .destructive) { point = nil }
                    } else {
                        Button("Use current location") { Task { point = await location.current() } }
                    }
                }
            }
            .navigationTitle(entity == nil ? "New" : "Edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(name.isEmpty) }
            }
            .onAppear(perform: load)
        }
    }

    func load() {
        guard let e = entity else { return }
        name = e.name; kind = e.kindName; notes = e.notes ?? ""; attributes = e.attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        sensitivity = e.sensitivity; categories = Set(e.categories); emergency = e.emergency; point = e.location
    }

    func save() {
        var e = entity ?? Entity(kindName: kind, name: name)
        e.name = name; e.kindName = kind; e.notes = notes.isEmpty ? nil : notes
        e.attributes = Dictionary(attributes.filter { !$0.0.isEmpty }, uniquingKeysWith: { $1 })
        e.categories = Array(categories); e.emergency = emergency; e.location = point
        e.sensitivity = max(sensitivity, SensitivityPolicy.minimumSensitivity(for: e.categories))
        if e.sensitivity == .restricted && !model.vaultUnlocked {
            Task { await model.unlockVault(); if model.vaultUnlocked { model.save(e); dismiss() } }
        } else {
            model.save(e); dismiss()
        }
    }
}

struct EventEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let entityID: String?
    @State private var kind: EventKind = .maintenance
    @State private var title = ""
    @State private var body_ = ""
    @State private var hasDue = false
    @State private var due = Date().addingTimeInterval(7 * 86400)
    @State private var cost = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) { ForEach(EventKind.allCases, id: \.self) { Text($0.rawValue.capitalized) } }
                TextField("What happened / what's needed", text: $title)
                TextField("Notes", text: $body_, axis: .vertical)
                TextField("Cost", text: $cost)
                Toggle("Due date", isOn: $hasDue)
                if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
            }
            .navigationTitle("Add to timeline")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.save(HouseholdEvent(eventKind: kind, title: title, body: body_.isEmpty ? nil : body_,
                                                  entityIDs: entityID.map { [$0] } ?? [], dueAt: hasDue ? due : nil, cost: cost.isEmpty ? nil : cost))
                        dismiss()
                    }.disabled(title.isEmpty)
                }
            }
        }
    }
}

struct ProceduresView: View {
    @EnvironmentObject var model: AppModel
    @State private var adding = false
    var body: some View {
        List(model.procedures, id: \.id) { p in
            NavigationLink { ProcedureView(procedure: p) } label: {
                Label(p.title, systemImage: p.emergency ? "cross.case.fill" : "list.number")
            }
        }
        .navigationTitle("Procedures")
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $adding) { ProcedureEditor(procedure: nil) }
    }
}

/// Plain text, large type, no AI, no network, no vault: always readable.
struct ProcedureView: View {
    let procedure: Procedure
    @State private var editing = false
    var body: some View {
        List {
            if let s = procedure.summary { Text(s) }
            ForEach(Array(procedure.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)").font(.title2.bold()).frame(width: 32)
                    Text(step).font(.title3)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(procedure.title)
        .toolbar { Button("Edit") { editing = true } }
        .sheet(isPresented: $editing) { ProcedureEditor(procedure: procedure) }
    }
}

struct ProcedureEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let procedure: Procedure?
    @State private var title = ""
    @State private var steps: [String] = [""]
    @State private var emergency = false
    @State private var entityID = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                Toggle("Emergency procedure", isOn: $emergency)
                Picker("For", selection: $entityID) {
                    Text("—").tag("")
                    ForEach(model.entities, id: \.id) { Text($0.name).tag($0.id) }
                }
                Section("Steps") {
                    ForEach(steps.indices, id: \.self) { i in
                        TextField("Step \(i + 1)", text: Binding(get: { steps[i] }, set: { steps[i] = $0 }), axis: .vertical)
                    }
                    Button("Add step") { steps.append("") }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var p = procedure ?? Procedure(title: title, steps: [])
                        p.title = title; p.steps = steps.filter { !$0.isEmpty }; p.emergency = emergency
                        p.entityIDs = entityID.isEmpty ? [] : [entityID]
                        model.save(p); dismiss()
                    }.disabled(title.isEmpty)
                }
            }
            .onAppear {
                if let p = procedure { title = p.title; steps = p.steps; emergency = p.emergency; entityID = p.entityIDs.first ?? "" }
            }
        }
    }
}
