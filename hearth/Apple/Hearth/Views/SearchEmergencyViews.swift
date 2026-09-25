import HearthCore
import SwiftUI

/// Local search over decrypted records (in memory). Works in Airplane Mode.
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var hits: [HearthStore.SearchHit] = []

    var body: some View {
        NavigationStack {
            List(hits, id: \.record.id) { hit in
                NavigationLink { destination(hit.record) } label: {
                    VStack(alignment: .leading) {
                        Text(hit.record.title)
                        Text(hit.record.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if !query.isEmpty && hits.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Shutoff, filter size, warranty…")
            .onChange(of: query) { _, q in hits = (try? model.store?.search(q)) ?? [] }
            .safeAreaInset(edge: .bottom) {
                if model.lockedCount > 0 {
                    Text("\(model.lockedCount) protected record(s) aren't searched until unlocked.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }
        }
    }

    @ViewBuilder func destination(_ env: RecordEnvelope) -> some View {
        switch env.kind {
        case .entity: EntityDetailView(entityID: env.id)
        case .procedure: if let p = try? env.decode(Procedure.self) { ProcedureView(procedure: p) }
        case .media: if let m = try? env.decode(MediaObject.self) { MediaViewer(media: m) }
        default:
            List { ForEach(env.fields.sorted(by: { $0.key < $1.key }), id: \.key) { LabeledContent($0.key, value: ConflictsView.show($0.value)) } }
        }
    }
}

/// Emergency information: readable with no network, no AI, no vault.
struct EmergencyView: View {
    @EnvironmentObject var model: AppModel
    @State private var records: [RecordEnvelope] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Stored on this device. Available without internet.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Procedures") {
                    ForEach(model.procedures.filter(\.emergency), id: \.id) { p in
                        NavigationLink { ProcedureView(procedure: p) } label: { Label(p.title, systemImage: "cross.case.fill").font(.headline) }
                    }
                }
                Section("Critical places & contacts") {
                    ForEach(records.filter { $0.kind == .entity }, id: \.id) { env in
                        NavigationLink { EntityDetailView(entityID: env.id) } label: {
                            VStack(alignment: .leading) {
                                Text(env.title).font(.headline)
                                if let n = env.fields["notes"]?.stringValue { Text(n).font(.subheadline) }
                            }
                        }
                    }
                }
                if model.procedures.filter(\.emergency).isEmpty && records.isEmpty {
                    Text("Mark procedures and entities as Emergency information (water shutoff, gas, breaker panel, contacts, pet care, evacuation) and they will appear here.")
                }
                Section {
                    ShareLink(item: printable, preview: SharePreview("Emergency information")) { Label("Print or share a paper copy", systemImage: "printer") }
                }
            }
            .navigationTitle("Emergency")
            .task { records = (try? model.store?.emergencyRecords()) ?? [] }
        }
    }

    var printable: String {
        let titles = Dictionary(uniqueKeysWithValues: model.entities.map { ($0.id, $0.name) })
        return Markdown.emergency(records, procedures: model.procedures.filter(\.emergency), titles: titles)
    }
}
