import Foundation
@testable import HearthCore
import XCTest

final class SyncTests: XCTestCase {
    /// Owner's iPhone + a second adult's iPhone sharing a NAS folder.
    func makePair(_ tmp: TempDir) throws -> (HearthStore, HearthStore, DirectorySyncTransport) {
        let a = try makeStore(tmp, name: "jimmy")
        let yvonne = Identity(displayName: "Yvonne", role: .adult)
        try a.save(yvonne)
        try a.unlockVault()
        let code = PairingCode.generate()
        let sealed = try a.enrollDevice(name: "Yvonne's iPhone", platform: "iOS", for: yvonne.id, pairingCode: code)
        let enrollment = try HearthStore.openEnrollment(sealed, pairingCode: code)
        let b = try HearthStore.joinHousehold(at: tmp.sub("yvonne"), keyStore: MemoryKeyStore(), enrollment: enrollment)
        let nas = try DirectorySyncTransport(folder: tmp.sub("nas"))
        _ = try a.sync(with: nas)
        _ = try b.sync(with: nas)
        return (a, b, nas)
    }

    func testEnrollmentRequiresCorrectPairingCode() throws {
        let tmp = TempDir()
        let a = try makeStore(tmp)
        let sealed = try a.enrollDevice(name: "iPad", platform: "iPadOS", for: a.identityID, pairingCode: "AAAA-BBBB-CCCC")
        XCTAssertThrowsError(try HearthStore.openEnrollment(sealed, pairingCode: "AAAA-BBBB-CCCD"))
        XCTAssertNoThrow(try HearthStore.openEnrollment(sealed, pairingCode: "aaaa bbbb cccc"))
    }

    func testReplicationIncludingMedia() throws {
        let tmp = TempDir()
        let (a, b, nas) = try makePair(tmp)
        let house = Entity(kindName: "home", name: "Maple Street house")
        try a.save(house)
        let photo = try a.media.importOriginal(data: Data(repeating: 7, count: 3_000_000), filename: "front.jpg",
                                               kind: .photo, mimeType: "image/jpeg", attachTo: house.id)
        _ = try a.sync(with: nas)
        let report = try b.sync(with: nas)
        XCTAssertEqual(report.blobsFetched, 1)
        XCTAssertEqual(try b.currentIdentity().displayName, "Yvonne")
        XCTAssertEqual(try b.fetch(Entity.self, id: house.id)?.name, "Maple Street house")
        XCTAssertEqual(try b.media.data(for: XCTUnwrap(b.fetch(MediaObject.self, id: photo.id))).count, 3_000_000)
        // Bundles in the shared folder are ciphertext.
        for name in try nas.listBundles() {
            XCTAssertNil(try nas.readBundle(name).range(of: Data("Maple".utf8)))
        }
    }

    func testOfflineEditsMergeAndConcurrentEditsAreSurfacedNotLost() throws {
        let tmp = TempDir()
        let (a, b, nas) = try makePair(tmp)
        var gen = Entity(kindName: "appliance", name: "Generator", attributes: ["oil": "5W-30"])
        try a.save(gen)
        _ = try a.sync(with: nas); _ = try b.sync(with: nas)

        // Both phones offline; both edit.
        gen.notes = "Exercise monthly"                      // Jimmy: notes
        try a.save(gen)
        var yv = try XCTUnwrap(b.fetch(Entity.self, id: gen.id))
        yv.attributes["oil"] = "10W-30 (winter)"             // Yvonne: attributes
        yv.name = "Backup generator"
        try b.save(yv)
        var jim2 = try XCTUnwrap(a.fetch(Entity.self, id: gen.id))
        jim2.name = "Standby generator"                      // Jimmy: also renames -> conflict
        try a.save(jim2)

        // Reconnect.
        _ = try a.sync(with: nas); _ = try b.sync(with: nas); _ = try a.sync(with: nas)

        let fa = try XCTUnwrap(a.fetch(Entity.self, id: gen.id))
        let fb = try XCTUnwrap(b.fetch(Entity.self, id: gen.id))
        XCTAssertEqual(fa, fb, "replicas converge")
        XCTAssertEqual(fa.notes, "Exercise monthly")          // non-conflicting edits both kept
        XCTAssertEqual(fa.attributes["oil"], "10W-30 (winter)")

        let conflicts = try a.conflicts()
        XCTAssertEqual(conflicts.map(\.field), ["name"])
        let values = Set([conflicts[0].winningValue, conflicts[0].losingValue])
        XCTAssertEqual(values, [.string("Standby generator"), .string("Backup generator")]) // nothing discarded

        try a.resolve(conflicts[0], with: .custom(.string("Standby generator (Generac)")))
        XCTAssertTrue(try a.conflicts().isEmpty)
        _ = try a.sync(with: nas); _ = try b.sync(with: nas)
        XCTAssertEqual(try b.fetch(Entity.self, id: gen.id)?.name, "Standby generator (Generac)")
        XCTAssertEqual(try b.history(of: gen.id).count, try a.history(of: gen.id).count)
    }

    func testSequentialEditsAcrossDevicesAreNotConflicts() throws {
        let tmp = TempDir()
        let (a, b, nas) = try makePair(tmp)
        var e = Entity(kindName: "room", name: "Den")
        try a.save(e)
        _ = try a.sync(with: nas); _ = try b.sync(with: nas)
        var eb = try XCTUnwrap(b.fetch(Entity.self, id: e.id)); eb.name = "Office"; try b.save(eb)
        _ = try b.sync(with: nas); _ = try a.sync(with: nas)
        e = try XCTUnwrap(a.fetch(Entity.self, id: e.id)); e.name = "Home office"; try a.save(e)
        _ = try a.sync(with: nas); _ = try b.sync(with: nas)
        XCTAssertTrue(try a.conflicts().isEmpty)
        XCTAssertTrue(try b.conflicts().isEmpty)
        XCTAssertEqual(try b.fetch(Entity.self, id: e.id)?.name, "Home office")
    }

    func testRevokedDeviceChangesAreRejected() throws {
        let tmp = TempDir()
        let (a, b, nas) = try makePair(tmp)
        try a.revokeDevice(b.deviceID)
        _ = try a.sync(with: nas)
        // The lost phone (not yet aware) keeps writing.
        try b.save(Entity(kindName: "note", name: "written after loss"))
        _ = try b.sync(with: nas)
        let report = try a.sync(with: nas)
        XCTAssertFalse(report.rejected.isEmpty)
        XCTAssertTrue(try a.search("written after loss").isEmpty)
    }

    func testPurgePropagates() throws {
        let tmp = TempDir()
        let (a, b, nas) = try makePair(tmp)
        let e = Entity(kindName: "note", name: "Delete me everywhere")
        try a.save(e)
        let m = try a.media.importOriginal(data: Data("bytes".utf8), filename: "x.txt", kind: .text, mimeType: "text/plain", attachTo: e.id)
        _ = try a.sync(with: nas); _ = try b.sync(with: nas)
        XCTAssertNotNil(try b.envelope(m.id))
        try a.purge(m.id)
        try a.purge(e.id)
        _ = try a.sync(with: nas); _ = try b.sync(with: nas)
        XCTAssertNil(try b.envelope(e.id))
        XCTAssertNil(try b.envelope(m.id))
        XCTAssertTrue(try b.history(of: e.id).allSatisfy { $0.values == nil })
        XCTAssertEqual(try b.stats()["_blobs"], 0)
    }

    func testRestrictedOpsWaitForVaultOnReceivingDevice() throws {
        let tmp = TempDir()
        let (a, b, nas) = try makePair(tmp)
        let acct = Entity(kindName: "account", name: "Mortgage", attributes: ["account": "0042-7781"], categories: [.financial])
        try a.save(acct)
        _ = try a.sync(with: nas)
        let r = try b.sync(with: nas)
        XCTAssertEqual(r.deferred, 1)
        XCTAssertNil(try? b.envelope(acct.id))
        try b.unlockVault()
        XCTAssertEqual(try b.fetch(Entity.self, id: acct.id)?.attributes["account"], "0042-7781")
    }
}
