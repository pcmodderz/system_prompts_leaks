import Foundation
@testable import HearthCore
import XCTest

final class MediaTests: XCTestCase {
    func testChunkedCipherRoundTripAndTamperDetection() throws {
        let tmp = TempDir()
        let key = SymmetricKey(size: .bits256)
        for size in [0, 1, 1000, ChunkedCipher.defaultChunkSize, ChunkedCipher.defaultChunkSize * 2 + 17] {
            let input = tmp.sub("in-\(size)")
            try Data((0..<size).map { UInt8($0 % 251) }).write(to: input)
            let enc = tmp.sub("enc-\(size)"), dec = tmp.sub("dec-\(size)")
            try ChunkedCipher.encrypt(input: input, output: enc, key: key)
            try ChunkedCipher.decrypt(input: enc, output: dec, key: key)
            XCTAssertEqual(try Data(contentsOf: dec), try Data(contentsOf: input))
        }
        // Truncation (drop the final chunk) must be detected.
        let big = tmp.sub("enc-\(ChunkedCipher.defaultChunkSize * 2 + 17)")
        var bytes = try Data(contentsOf: big)
        bytes = bytes.prefix(bytes.count - 17 - 28)
        try bytes.write(to: tmp.sub("truncated"))
        XCTAssertThrowsError(try ChunkedCipher.decrypt(input: tmp.sub("truncated"), output: tmp.sub("x"), key: key))
    }

    func testImportIsContentAddressedImmutableAndDeduplicated() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        let src = tmp.sub("IMG_0001.JPG")
        let original = Data((0..<500_000).map { _ in UInt8.random(in: 0...255) })
        try original.write(to: src)
        let pool = Entity(kindName: "equipment", name: "Pool pump")
        try store.save(pool)

        let m1 = try store.media.importOriginal(file: src, kind: .photo, mimeType: "image/jpeg", attachTo: pool.id)
        let m2 = try store.media.importOriginal(file: src, kind: .photo, mimeType: "image/jpeg")
        XCTAssertEqual(m1.id, m2.id, "same bytes -> same media, no second copy")
        XCTAssertEqual(try store.stats()["_blobs"], 1)
        XCTAssertEqual(try Data(contentsOf: src), original, "source file untouched")
        XCTAssertEqual(try store.media.data(for: m1), original)
        XCTAssertEqual(try store.media.media(attachedTo: pool.id).map(\.id), [m1.id])

        // Blob on disk is ciphertext and not named by the public hash.
        let blob = try store.media.blobURL(for: m1)
        XCTAssertFalse(blob.lastPathComponent.contains(m1.sha256))
        XCTAssertNil(try Data(contentsOf: blob).range(of: original.prefix(64)))

        // Derivatives are separate; deleting one leaves the original.
        let thumb = try store.media.addDerivative(of: m1, role: .thumbnail, data: Data("thumb".utf8), mimeType: "image/jpeg", producedBy: "test")
        let ai = try store.media.addDerivative(of: m1, role: .aiAnalysis, data: Data("{\"label\":\"pump\"}".utf8), mimeType: "application/json", producedBy: "test")
        try store.media.deleteDerivative(ai)
        XCTAssertEqual(try store.media.derivatives(of: m1).map(\.id), [thumb.id])
        XCTAssertEqual(try store.media.data(for: m1), original)
        XCTAssertThrowsError(try store.media.deleteDerivative(m1))

        // Editing metadata never rewrites the original bytes.
        var edited = m1; edited.caption = "Pump label"
        try store.save(edited)
        XCTAssertEqual(try store.media.data(for: XCTUnwrap(store.fetch(MediaObject.self, id: m1.id))), original)
        XCTAssertTrue(try store.media.verifyAll().ok)
    }
}

final class LiveDataTests: XCTestCase {
    func testFetchStoreFreshnessOfflineAndHistory() async throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        let http = FakeHTTP(body: sampleOpenMeteo)
        store.live.register(OpenMeteoConnector(http: http))
        let home = Entity(kindName: "home", name: "House", location: GeoPoint(latitude: 40.712776, longitude: -74.005974))
        try store.save(home)
        let source = OpenMeteoConnector.makeSource(name: "Weather", location: home.location!, entityID: home.id)
        try store.save(source)

        XCTAssertEqual(try store.live.readings(for: source).first?.freshness, .unavailable)
        let t0 = Date()
        guard case .updated(7) = await store.live.refresh(source, now: t0) else { return XCTFail("expected 7 metrics") }
        // Only a coarsened coordinate left the device.
        let q = http.requests[0].query ?? ""
        XCTAssertTrue(q.contains("latitude=40.71") && !q.contains("40.7127"))

        let temp = try XCTUnwrap(store.live.readings(for: source, now: t0).first { $0.observation?.metric == "temperature_2m" })
        XCTAssertEqual(temp.freshness, .fresh)
        XCTAssertEqual(temp.observation?.value, .number(18.4))
        XCTAssertEqual(temp.observation?.unit, "°C")

        // Network goes away: value stays, marked OFFLINE.
        http.offline = true
        let t1 = t0.addingTimeInterval(600)
        guard case .failed(_, connectivity: true) = await store.live.refresh(source, now: t1) else { return XCTFail() }
        let offline = try store.live.readings(for: source, now: t1)
        XCTAssertEqual(offline.count, 7)
        XCTAssertTrue(offline.allSatisfy { $0.freshness == .offline && $0.observation != nil })

        // Much later with no network still shows the value, still offline.
        XCTAssertEqual(try store.live.readings(for: source, now: t0.addingTimeInterval(86400)).first?.freshness, .offline)

        // Back online, new observation time -> fresh, and history retained.
        http.offline = false
        http.body = Data(String(decoding: sampleOpenMeteo, as: UTF8.self).replacingOccurrences(of: "03:15", with: "04:00").replacingOccurrences(of: "18.4", with: "17.1").utf8)
        let t2 = t0.addingTimeInterval(3600)
        _ = await store.live.refresh(source, now: t2)
        let now = try XCTUnwrap(store.live.readings(for: source, now: t2).first { $0.observation?.metric == "temperature_2m" })
        XCTAssertEqual(now.freshness, .fresh)
        XCTAssertEqual(now.observation?.value, .number(17.1))
        XCTAssertEqual(try store.live.observations(sourceID: source.id, metric: "temperature_2m").map(\.value), [.number(17.1), .number(18.4)])

        // Stale after max age with no new fetch.
        XCTAssertEqual(try store.live.readings(for: source, now: t2.addingTimeInterval(4 * 3600)).first?.freshness, .stale)
    }
}

final class AIPolicyTests: XCTestCase {
    func testRoutingAndApprovals() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        try store.save(Entity(kindName: "appliance", name: "Dishwasher", notes: "Bosch SHX878, error E24 means drain clog"))
        try store.save(Entity(kindName: "person", name: "Grandma medical notes", notes: "Dishwasher-safe pill organizer", sensitivity: .private, categories: [.medical]))
        let engine = AIPolicyEngine(store: store)

        let lan = AIEndpoint(name: "Mac Studio", location: .householdMac, baseURL: URL(string: "http://mac.local:11434/v1"), model: "llama3")
        let ext = AIEndpoint(name: "Cloud", location: .external, baseURL: URL(string: "https://api.example.com/v1"), model: "m", provider: "Example AI")

        let ctxLAN = try ContextBuilder.minimal(store: store, question: "dishwasher E24", for: lan)
        guard case .allowed = try engine.evaluate(AIRequest(purpose: "troubleshoot", prompt: "What is E24?", endpoint: lan, context: ctxLAN)) else { return XCTFail() }

        // External is off by default.
        let ctxExt = try ContextBuilder.minimal(store: store, question: "dishwasher", for: ext)
        guard case .denied = try engine.evaluate(AIRequest(purpose: "troubleshoot", prompt: "?", endpoint: ext, context: ctxExt)) else { return XCTFail() }

        engine.settings.externalAIEnabled = true
        // Private medical record in context -> always asks.
        XCTAssertTrue(ctxExt.contains { $0.sensitivity == .private })
        guard case .needsApproval(let c) = try engine.evaluate(AIRequest(purpose: "troubleshoot", prompt: "?", endpoint: ext, context: ctxExt)) else { return XCTFail() }
        XCTAssertTrue(c.summary.contains("Example AI"))

        // Normal context: ask once, then "allow for this source" is remembered.
        let normalOnly = ctxExt.filter { $0.sensitivity == .normal }
        let req = AIRequest(purpose: "troubleshoot", prompt: "?", endpoint: ext, context: normalOnly)
        guard case .needsApproval = try engine.evaluate(req) else { return XCTFail() }
        XCTAssertNotNil(try engine.approve(req, choice: .allowForSource))
        guard case .allowed = try engine.evaluate(req) else { return XCTFail() }
        XCTAssertNil(try engine.approve(req, choice: .deny))

        // Media never goes out unless explicitly enabled.
        guard case .denied = try engine.evaluate(AIRequest(purpose: "identify", prompt: "?", endpoint: ext, mediaIDs: ["x"])) else { return XCTFail() }

        // Every decision is audited locally.
        XCTAssertGreaterThanOrEqual(try store.db.query("SELECT COUNT(*) AS n FROM ai_disclosures").first?.int("n") ?? 0, 6)
    }

    func testRestrictedNeverInExternalContext() throws {
        let tmp = TempDir()
        let store = try makeStore(tmp)
        try store.unlockVault()
        try store.save(Entity(kindName: "network", name: "Wifi router", attributes: ["password": "hunter2"], categories: [.network]))
        let ext = AIEndpoint(name: "Cloud", location: .external, model: "m", provider: "X")
        let lan = AIEndpoint(name: "NAS", location: .householdServer, model: "m")
        XCTAssertTrue(try ContextBuilder.minimal(store: store, question: "wifi router", for: ext).isEmpty)
        XCTAssertEqual(try ContextBuilder.minimal(store: store, question: "wifi router", for: lan).count, 1)
    }
}

import Crypto
