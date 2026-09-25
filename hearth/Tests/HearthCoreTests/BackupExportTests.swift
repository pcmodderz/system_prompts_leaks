import Foundation
@testable import HearthCore
import XCTest

final class BackupExportTests: XCTestCase {
    func populate(_ store: HearthStore) throws -> (Entity, MediaObject) {
        let shutoff = Entity(kindName: "utility", name: "Water main shutoff", notes: "Basement NE corner",
                             location: GeoPoint(latitude: 40.7128, longitude: -74.006), emergency: true)
        try store.save(shutoff)
        try store.save(Procedure(title: "Shut off water", steps: ["Go to basement NE corner", "Turn blue handle clockwise"],
                                 entityIDs: [shutoff.id], emergency: true))
        try store.unlockVault()
        try store.save(Entity(kindName: "document", name: "Passport - Jimmy", attributes: ["number": "X1234567"], categories: [.identity]))
        let photo = try store.media.importOriginal(data: Data((0..<200_000).map { UInt8($0 % 256) }), filename: "valve.heic",
                                                   kind: .photo, mimeType: "image/heic", location: GeoPoint(latitude: 40.71, longitude: -74.0),
                                                   attachTo: shutoff.id)
        return (shutoff, photo)
    }

    func testBackupVerifyTestRestoreRestoreWithEitherSecret() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        let (shutoff, photo) = try populate(store)
        let recovery = RecoveryKey.generate()
        XCTAssertEqual(RecoveryKey(displayString: recovery.displayString), recovery)

        let receipt = try BackupManager.createBackup(of: store, to: tmp.sub("usb"), passphrase: "correct horse battery", recoveryKey: recovery)
        XCTAssertNil(try BackupManager.log(store).first?.verifiedByTestRestore, "not verified until test-restored")

        XCTAssertTrue(try BackupManager.verify(receipt.location, secret: .passphrase("correct horse battery")).ok)
        XCTAssertThrowsError(try BackupManager.verify(receipt.location, secret: .passphrase("wrong")))

        let test = try BackupManager.testRestore(receipt.location, secret: .recoveryKey(recovery), recordingIn: store)
        XCTAssertTrue(test.ok, test.description)
        XCTAssertNotNil(try BackupManager.log(store).first?.verifiedByTestRestore)

        // Phone lost: restore onto a new device with only the recovery key.
        let newKeys = MemoryKeyStore()
        let restored = try BackupManager.restore(receipt.location, secret: .recoveryKey(recovery), into: tmp.sub("new-phone"), keyStore: newKeys)
        XCTAssertEqual(try restored.fetch(Entity.self, id: shutoff.id)?.notes, "Basement NE corner")
        XCTAssertEqual(try restored.media.data(for: photo).count, 200_000)
        XCTAssertEqual(try restored.history(of: shutoff.id).count, try store.history(of: shutoff.id).count)
        try restored.unlockVault()
        XCTAssertEqual(try restored.search("X1234567").count, 1)

        // Tampering is detected.
        let db = receipt.location.appendingPathComponent("database.hblob")
        var bytes = try Data(contentsOf: db); bytes[bytes.count / 2] ^= 0xFF; try bytes.write(to: db)
        XCTAssertFalse(try BackupManager.verify(receipt.location, secret: .recoveryKey(recovery)).ok)
    }

    func testOpenExportIsUsableWithoutHearth() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        let (_, photo) = try populate(store)
        store.lockVault()
        let result = try Exporter.export(store, to: tmp.sub("exports"), options: .init(stripLocation: true))
        let dir = result.directory
        XCTAssertEqual(result.skippedRestricted, 1)

        // Original media byte-for-byte, named by hash.
        let orig = dir.appendingPathComponent("media/originals/\(photo.sha256).heic")
        XCTAssertEqual(try Hashing.sha256Hex(fileAt: orig), photo.sha256)

        // Plain JSON, no location, no restricted data.
        let entities = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("records/entity.json"))) as! [[String: Any]]
        XCTAssertEqual(entities.count, 1)
        XCTAssertNil(entities[0]["location"])
        let all = try String(contentsOf: dir.appendingPathComponent("history/operations.jsonl"), encoding: .utf8)
        XCTAssertFalse(all.contains("X1234567"))
        XCTAssertFalse(all.contains("40.7128"))

        let emergency = try String(contentsOf: dir.appendingPathComponent("EMERGENCY.md"), encoding: .utf8)
        XCTAssertTrue(emergency.contains("Turn blue handle clockwise"))

        // Manifest checksums match.
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as! [String: Any]
        for f in manifest["files"] as! [[String: Any]] {
            XCTAssertEqual(try Hashing.sha256Hex(fileAt: dir.appendingPathComponent(f["path"] as! String)), f["sha256"] as? String)
        }
    }
}
