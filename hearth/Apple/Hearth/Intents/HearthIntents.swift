import AppIntents
import HearthCore
import SwiftUI

// Siri / Shortcuts / Spotlight actions. All require the device to be unlocked, all read the
// local store only, and none of them can open protected (vault) records.

struct ProcedureEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Procedure")
    static var defaultQuery = ProcedureQuery()
    var id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct ProcedureQuery: EntityStringQuery {
    func procedures() -> [Procedure] { (try? HearthRuntime.shared.store?.all(Procedure.self)) ?? [] }
    func entities(for identifiers: [String]) async throws -> [ProcedureEntity] {
        procedures().filter { identifiers.contains($0.id) }.map { ProcedureEntity(id: $0.id, title: $0.title) }
    }
    func entities(matching string: String) async throws -> [ProcedureEntity] {
        procedures().filter { $0.title.localizedCaseInsensitiveContains(string) }.map { ProcedureEntity(id: $0.id, title: $0.title) }
    }
    func suggestedEntities() async throws -> [ProcedureEntity] {
        procedures().map { ProcedureEntity(id: $0.id, title: $0.title) }
    }
}

struct ShowProcedureIntent: AppIntent {
    static var title: LocalizedStringResource = "Show procedure"
    static var description = IntentDescription("Reads a household procedure, e.g. the generator or water shutoff.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Procedure") var procedure: ProcedureEntity

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let p = try HearthRuntime.shared.store?.fetch(Procedure.self, id: procedure.id) else {
            return .result(dialog: "I couldn't find that procedure.", view: Text(""))
        }
        let spoken = p.steps.enumerated().map { "Step \($0.offset + 1). \($0.element)" }.joined(separator: " ")
        return .result(dialog: "\(p.title). \(spoken)", view: ProcedureSnippet(procedure: p))
    }
}

struct ProcedureSnippet: View {
    let procedure: Procedure
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(procedure.steps.enumerated()), id: \.offset) { Text("\($0.offset + 1). \($0.element)") }
        }.padding()
    }
}

struct WhatsDueIntent: AppIntent {
    static var title: LocalizedStringResource = "What's due this week"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let due = (try? HearthRuntime.shared.store?.dueEvents(within: 7 * 86400)) ?? []
        if due.isEmpty { return .result(dialog: "Nothing is due this week.") }
        return .result(dialog: "\(due.count) due: " + due.map(\.title).joined(separator: ", "))
    }
}

struct RecordMaintenanceIntent: AppIntent {
    static var title: LocalizedStringResource = "Record maintenance"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "What was done") var what: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = HearthRuntime.shared.store else { return .result(dialog: "Hearth isn't set up yet.") }
        try store.save(HouseholdEvent(eventKind: .maintenance, title: what, completedAt: Date()), provenance: Provenance(.manual, source: "shortcuts"))
        return .result(dialog: "Recorded: \(what).")
    }
}

struct AddNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Add this to Hearth"
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Parameter(title: "Note") var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = HearthRuntime.shared.store else { return .result(dialog: "Hearth isn't set up yet.") }
        try store.save(HouseholdEvent(eventKind: .note, title: String(text.prefix(80)), body: text), provenance: Provenance(.manual, source: "shortcuts"))
        return .result(dialog: "Added to Hearth.")
    }
}

struct ShowWaterShutoffIntent: AppIntent {
    static var title: LocalizedStringResource = "Show the water shutoff"
    static var openAppWhenRun = true
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hits = (try? HearthRuntime.shared.store?.search("water shutoff")) ?? []
        guard let top = hits.first else { return .result(dialog: "No water shutoff is recorded yet.") }
        let notes = top.record.fields["notes"]?.stringValue ?? ""
        return .result(dialog: "\(top.record.title). \(notes)")
    }
}

struct HearthShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ShowProcedureIntent(), phrases: ["Show the \(\.$procedure) procedure in \(.applicationName)", "\(.applicationName) procedure"],
                    shortTitle: "Procedure", systemImageName: "list.number")
        AppShortcut(intent: WhatsDueIntent(), phrases: ["What's due this week in \(.applicationName)"], shortTitle: "What's due", systemImageName: "calendar")
        AppShortcut(intent: RecordMaintenanceIntent(), phrases: ["Record maintenance in \(.applicationName)"], shortTitle: "Record maintenance", systemImageName: "wrench")
        AppShortcut(intent: AddNoteIntent(), phrases: ["Add this to \(.applicationName)"], shortTitle: "Add to Hearth", systemImageName: "plus")
        AppShortcut(intent: ShowWaterShutoffIntent(), phrases: ["Show the water shutoff in \(.applicationName)"], shortTitle: "Water shutoff", systemImageName: "drop")
    }
}
