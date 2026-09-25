import CoreLocation
import Foundation
import HearthCore
import SwiftUI

/// Shared access to the open store for the app, App Intents and background tasks.
final class HearthRuntime: @unchecked Sendable {
    static let shared = HearthRuntime()
    let keyStore = KeychainKeyStore()
    private let lock = NSLock()
    private var _store: HearthStore?

    var store: HearthStore? {
        lock.lock(); defer { lock.unlock() }
        if _store == nil, FileManager.default.fileExists(atPath: AppPaths.storeRoot.appendingPathComponent(HearthStore.databaseName).path) {
            _store = try? HearthStore.open(at: AppPaths.storeRoot, keyStore: keyStore)
            _store?.live.credentials = KeychainCredentialStore()
        }
        return _store
    }

    func adopt(_ store: HearthStore) {
        lock.lock(); _store = store; lock.unlock()
        store.live.credentials = KeychainCredentialStore()
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case loading, onboarding, ready, failed(String) }

    @Published var phase: Phase = .loading
    @Published var entities: [Entity] = []
    @Published var procedures: [Procedure] = []
    @Published var due: [HouseholdEvent] = []
    @Published var recentMedia: [MediaObject] = []
    @Published var liveReadings: [LiveReading] = []
    @Published var conflicts: [Conflict] = []
    @Published var inbox: [PendingInboxItem] = []
    @Published var lockedCount = 0
    @Published var vaultUnlocked = false
    @Published var lastSync: SyncReport?
    @Published var lastError: String?

    let connectivity = Connectivity()
    let runtime = HearthRuntime.shared
    var store: HearthStore? { runtime.store }

    init() {
        connectivity.onReconnect = { [weak self] in Task { await self?.reconnected() } }
    }

    // MARK: Lifecycle

    func start() {
        if store != nil {
            phase = .ready
            reload()
            Task { await refreshLive(); syncIfConfigured() }
        } else {
            phase = .onboarding
        }
    }

    func createHousehold(name: String, owner: String) {
        do {
            let store = try HearthStore.createHousehold(at: AppPaths.storeRoot, keyStore: runtime.keyStore,
                                                        householdName: name, ownerName: owner,
                                                        deviceName: UIDevice.current.name, platform: UIDevice.current.systemName)
            runtime.adopt(store)
            _ = try InboxKey.privateKey()
            phase = .ready
            reload()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func joinHousehold(sealed: SealedEnrollment, code: String) {
        do {
            let enrollment = try HearthStore.openEnrollment(sealed, pairingCode: code)
            let store = try HearthStore.joinHousehold(at: AppPaths.storeRoot, keyStore: runtime.keyStore, enrollment: enrollment)
            runtime.adopt(store)
            _ = try InboxKey.privateKey()
            phase = .ready
            syncIfConfigured()
            reload()
        } catch {
            lastError = "Could not join: \(error)"
        }
    }

    /// Reads everything from the local store. Works identically in Airplane Mode.
    func reload() {
        guard let store else { return }
        do {
            entities = try store.all(Entity.self).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            procedures = try store.all(Procedure.self)
            due = try store.dueEvents(within: 7 * 86400)
            recentMedia = Array(try store.media.all(role: .original).sorted { $0.importedAt > $1.importedAt }.prefix(24))
            liveReadings = try store.live.sources().flatMap { try store.live.readings(for: $0) }
            conflicts = try store.conflicts()
            lockedCount = try store.lockedCount()
            vaultUnlocked = store.keys.isVaultUnlocked
            inbox = (try? store.pendingInboxItems(privateKey: InboxKey.privateKey())) ?? []
        } catch {
            lastError = error.localizedDescription
        }
    }

    func didEnterBackground() {
        store?.lockVault()
        vaultUnlocked = false
        try? FileManager.default.removeItem(at: AppPaths.playbackCache)
        BackgroundRefresh.schedule()
    }

    // MARK: Vault

    func unlockVault() async {
        guard let store else { return }
        do {
            try await Task.detached { try store.unlockVault() }.value
            reload()
        } catch KeyStoreError.userCancelled {
        } catch {
            lastError = "Couldn't unlock: \(error.localizedDescription)"
        }
    }

    func lockVault() { store?.lockVault(); reload() }

    // MARK: Writes (all local; sync later)

    func save<R: HearthRecord>(_ record: R, provenance: Provenance = .manual) {
        guard let store else { return }
        do { try store.save(record, provenance: provenance); reload() }
        catch HearthStoreError.vaultLocked { lastError = "Unlock protected records to save this." }
        catch { lastError = error.localizedDescription }
    }

    @discardableResult
    func importMedia(file: URL, kind: MediaKind, mimeType: String, capturedAt: Date?, location: GeoPoint?,
                     attachTo entityID: String?, provenance: Provenance) -> MediaObject? {
        guard let store else { return nil }
        do {
            let m = try store.media.importOriginal(file: file, kind: kind, mimeType: mimeType, capturedAt: capturedAt,
                                                   location: location, attachTo: entityID, provenance: provenance)
            reload()
            Task.detached(priority: .utility) {
                await OnDeviceProcessing.process(m, in: store)
                await MainActor.run { self.reload() }
            }
            return m
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func attach(_ mediaID: String, to entityID: String) {
        guard let store else { return }
        do { try store.link(mediaID, to: entityID, type: Relationship.attachedTo); reload() }
        catch { lastError = error.localizedDescription }
    }

    func file(_ item: PendingInboxItem, to entityID: String?) {
        guard let store else { return }
        do { try store.fileInboxItem(item, attachTo: entityID); reload() }
        catch { lastError = error.localizedDescription }
    }

    func resolve(_ conflict: Conflict, _ resolution: HearthStore.Resolution) {
        guard let store else { return }
        do { try store.resolve(conflict, with: resolution); reload() } catch { lastError = error.localizedDescription }
    }

    // MARK: Live data & sync

    func refreshLive() async {
        guard let store else { return }
        _ = await store.live.refreshAll()
        reload()
    }

    func reconnected() async {
        await refreshLive()
        syncIfConfigured()
    }

    func syncIfConfigured() {
        guard let store else { return }
        Task.detached(priority: .utility) {
            let report = try? SyncFolder.sync(store)
            await MainActor.run { self.lastSync = report; self.reload() }
        }
    }

    func addWeatherSource(for home: Entity) {
        guard let loc = home.location else { lastError = "Set the home's location first."; return }
        save(OpenMeteoConnector.makeSource(name: "Weather at \(home.name)", location: loc, entityID: home.id))
        Task { await refreshLive() }
    }
}

/// One-shot location for capture or the home's position. Only when the user allows it.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<GeoPoint?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async -> GeoPoint? {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: return nil
        default: break
        }
        return await withCheckedContinuation { c in
            continuation = c
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let point = locations.last.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, horizontalAccuracy: $0.horizontalAccuracy) }
        Task { @MainActor in continuation?.resume(returning: point); continuation = nil }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in continuation?.resume(returning: nil); continuation = nil }
    }
}
