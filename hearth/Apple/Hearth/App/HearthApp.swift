import HearthCore
import SwiftUI

@main
struct HearthApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundRefresh.register { HearthRuntime.shared.store }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch model.phase {
                case .loading: ProgressView()
                case .onboarding: OnboardingView()
                case .ready: RootView()
                case .failed(let message): ContentUnavailableView("Hearth couldn't open", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            }
            .environmentObject(model)
            .task { model.start() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: model.didEnterBackground()
                case .active: model.reload()
                default: break
                }
            }
            .alert("Hearth", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.lastError ?? "") }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house") }
            CaptureTab().tabItem { Label("Capture", systemImage: "camera") }
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
            EmergencyView().tabItem { Label("Emergency", systemImage: "cross.case") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var household = ""
    @State private var owner = ""
    @State private var joining = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Hearth keeps your household's information on your own devices. There is no Hearth account and no Hearth cloud. You can export or back up everything at any time.")
                        .font(.callout)
                }
                Section("New household") {
                    TextField("Household name (e.g. Maple Street)", text: $household)
                    TextField("Your name", text: $owner).textContentType(.givenName)
                    Button("Create household") { model.createHousehold(name: household, owner: owner) }
                        .disabled(household.isEmpty || owner.isEmpty)
                }
                Section("Already use Hearth?") {
                    Button("Join from another household device") { joining = true }
                    NavigationLink("Restore from backup") { RestoreView() }
                }
            }
            .navigationTitle("Welcome to Hearth")
            .sheet(isPresented: $joining) { JoinHouseholdView() }
        }
    }
}
