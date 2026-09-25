import Foundation
@testable import HearthCore
import XCTest

final class StoreTests: XCTestCase {
    func testCreateSaveReopenWithHistory() throws {
        let tmp = TempDir()
        let keys = MemoryKeyStore()
        var gen = Entity(kindName: "appliance", name: "Generator", attributes: ["model": "Generac 7043"])
        do {
            let store = try makeStore(tmp, keys: keys)
            try store.save(gen)
            gen.attributes["fuel"] = "natural gas"
            try store.save(gen)
            gen.name = "Standby generator"
            try store.save(gen)
            store.close()
        }
        let reopened = try HearthStore.open(at: tmp.sub("home"), keyStore: keys)
        let loaded = try XCTUnwrap(reopened.fetch(Entity.self, id: gen.id))
        XCTAssertEqual(loaded.name, "Standby generator")
        XCTAssertEqual(loaded.attributes["fuel"], "natural gas")
        let history = try reopened.history(of: gen.id)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.first?.values?["name"], .string("Generator"))
        XCTAssertEqual(history.last?.values?.keys.sorted(), ["name"]) // only changed fields
    }

    func testNothingReadableWithoutKeysAndNoPlaintextOnDisk() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        try store.save(Entity(kindName: "utility", name: "Main water shutoff", notes: "Basement, behind the furnace, blue handle"))
        store.close()
        let raw = try Data(contentsOf: tmp.sub("home/hearth.sqlite"))
        let wal = (try? Data(contentsOf: tmp.sub("home/hearth.sqlite-wal"))) ?? Data()
        for needle in ["Basement", "furnace", "blue handle", "Main water"] {
            XCTAssertNil(raw.range(of: Data(needle.utf8)), "plaintext \(needle) in database")
            XCTAssertNil(wal.range(of: Data(needle.utf8)), "plaintext \(needle) in WAL")
        }
        XCTAssertThrowsError(try HearthStore.open(at: tmp.sub("home"), keyStore: MemoryKeyStore()))
    }

    func testVaultRecordsNeedUnlockAndAreHiddenFromSearchWhenLocked() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        let policy = Entity(kindName: "insurance", name: "Home insurance policy", attributes: ["policyNumber": "HO-3-99812"],
                            categories: [.insurance])
        XCTAssertThrowsError(try store.save(policy)) { XCTAssertEqual($0 as? HearthStoreError, .vaultLocked) }
        try store.unlockVault()
        try store.save(policy)
        XCTAssertEqual(try store.envelope(policy.id)?.keyClass, .vault) // category forced restricted
        XCTAssertEqual(try store.search("HO-3-99812").count, 1)
        store.lockVault()
        XCTAssertThrowsError(try store.envelope(policy.id))
        XCTAssertEqual(try store.search("insurance").count, 0)
        XCTAssertEqual(try store.lockedCount(kind: .entity), 1)
        try store.unlockVault()
        XCTAssertEqual(try store.fetch(Entity.self, id: policy.id)?.attributes["policyNumber"], "HO-3-99812")
    }

    func testEmergencyRecordsCannotBeVaultSealed() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        let p = Procedure(title: "Gas leak", steps: ["Leave the house"], sensitivity: .restricted, emergency: true)
        XCTAssertThrowsError(try store.save(p))
        try store.save(Procedure(title: "Gas leak", steps: ["Leave the house", "Call gas company from outside"], emergency: true))
        XCTAssertEqual(try store.emergencyRecords().count, 1)
    }

    func testSearchAndDueEvents() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        let furnace = Entity(kindName: "appliance", name: "Furnace", attributes: ["filter": "16x25x1 MERV 11"])
        try store.save(furnace)
        try store.save(HouseholdEvent(eventKind: .maintenance, title: "Replace furnace filter", entityIDs: [furnace.id],
                                      dueAt: Date().addingTimeInterval(3 * 86400)))
        try store.save(HouseholdEvent(eventKind: .maintenance, title: "Flush water heater", dueAt: Date().addingTimeInterval(40 * 86400)))
        XCTAssertEqual(try store.search("merv").first?.record.id, furnace.id)
        XCTAssertEqual(try store.search("furn filt").count, 1) // prefix AND
        XCTAssertEqual(try store.dueEvents(within: 7 * 86400).map(\.title), ["Replace furnace filter"])
    }

    func testPermissions() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        let child = Identity(displayName: "Kid", role: .child)
        try store.save(child)
        try store.save(Entity(kindName: "note", name: "Surprise party plans", sensitivity: .private))
        try store.save(Entity(kindName: "room", name: "Kitchen"))
        try store.switchIdentity(to: child.id)
        XCTAssertEqual(try store.all(Entity.self).map(\.name), ["Kitchen"])
        XCTAssertThrowsError(try store.save(Entity(kindName: "x", name: "y", sensitivity: .private)))
    }

    func testPurgeRemovesContentEverywhereLocally() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        let e = Entity(kindName: "note", name: "Old alarm code 4471")
        try store.save(e)
        let photo = try store.media.importOriginal(data: Data("fake-jpeg-bytes-for-test".utf8), filename: "code.jpg",
                                                   kind: .photo, mimeType: "image/jpeg", attachTo: e.id)
        try store.media.addDerivative(of: photo, role: .ocrText, data: Data("4471".utf8), mimeType: "text/plain", producedBy: "test")
        _ = try BackupManager.createBackup(of: store, to: tmp.sub("bk"), passphrase: "pw", recoveryKey: .generate())
        let report = try store.purge(photo.id)
        XCTAssertEqual(report.mediaBlobsRemoved, 2)
        XCTAssertEqual(report.backupsThatMayStillContainData.count, 1)
        let report2 = try store.purge(e.id)
        XCTAssertTrue(report2.historyEntriesRedacted > 0)
        XCTAssertNil(try store.envelope(e.id))
        XCTAssertTrue(try store.history(of: e.id).allSatisfy { $0.redacted || $0.action == .purge })
        XCTAssertEqual(try store.search("4471").count, 0)
        XCTAssertEqual(try store.media.all().count, 0)
    }

    func testSchemaMigrationIsIdempotentAndPreservesData() throws {
        let tmp = TempDir()
        let keys = MemoryKeyStore()
        let store = try makeStore(tmp, keys: keys)
        try store.save(Entity(kindName: "room", name: "Garage"))
        try Schema.migrate(store.db)
        store.close()
        let again = try HearthStore.open(at: tmp.sub("home"), keyStore: keys)
        XCTAssertEqual(try again.all(Entity.self).map(\.name), ["Garage"])
    }

    func testUnknownFieldsFromNewerVersionsArePreserved() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        var e = Entity(kindName: "vehicle", name: "Truck")
        try store.save(e)
        // A newer app version adds a field this version doesn't know about.
        try store.write(kind: .entity, id: e.id, fields: ["futureField": .string("kept")], provenance: .manual, replace: false)
        e.name = "Pickup truck"
        try store.save(e)
        let fields = try XCTUnwrap(store.envelope(e.id)).fields
        XCTAssertEqual(fields["name"], .string("Pickup truck"))
        XCTAssertEqual(fields["futureField"], .string("kept"))
        e.notes = "note"; try store.save(e)
        e.notes = nil; try store.save(e) // clearing a known optional still works
        XCTAssertNil(try store.fetch(Entity.self, id: e.id)?.notes)
        XCTAssertEqual(try store.envelope(e.id)?.fields["futureField"], .string("kept"))
    }
}
