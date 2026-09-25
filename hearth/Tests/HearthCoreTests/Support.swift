import Foundation
@testable import HearthCore
import XCTest

final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func sub(_ name: String) -> URL { url.appendingPathComponent(name) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

func makeStore(_ tmp: TempDir, name: String = "home", keys: KeyStore = MemoryKeyStore()) throws -> HearthStore {
    try HearthStore.createHousehold(at: tmp.sub(name), keyStore: keys, householdName: "Test Household",
                                    ownerName: "Owner", deviceName: "Owner iPhone", platform: "test")
}

/// Serves canned HTTP responses or simulates the network being down.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var body: Data
    var status = 200
    var offline = false
    var requests: [URL] = []
    init(body: Data) { self.body = body }
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        requests.append(url)
        if offline { throw URLError(.notConnectedToInternet) }
        return (body, status)
    }
}

let sampleOpenMeteo = Data("""
{"latitude":40.71,"longitude":-74.01,"current_units":{"time":"iso8601","interval":"seconds","temperature_2m":"°C","apparent_temperature":"°C","relative_humidity_2m":"%","precipitation":"mm","weather_code":"wmo code","wind_speed_10m":"km/h","wind_gusts_10m":"km/h"},
 "current":{"time":"2026-09-25T03:15","interval":900,"temperature_2m":18.4,"apparent_temperature":17.9,"relative_humidity_2m":71,"precipitation":0.0,"weather_code":3,"wind_speed_10m":9.7,"wind_gusts_10m":21.2}}
""".utf8)
