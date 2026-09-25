import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How trustworthy a live value is right now. The UI always shows this next to the value;
/// a value never disappears just because its source is unreachable.
public enum Freshness: String, Codable, Sendable {
    /// Streaming connection is open and delivering (only for push/stream connectors).
    case live
    /// Last successful fetch is within the source's max age.
    case fresh
    /// Older than max age (or the source is erroring); last known value still shown.
    case stale
    /// The last attempt failed because the network/source was unreachable; showing last value.
    case offline
    /// Never successfully fetched.
    case unavailable
    /// Source turned off by the household.
    case disabled
}

public struct ObservationDraft: Sendable, Equatable {
    public var metric: String
    public var value: JSONValue
    public var unit: String?
    public var observedAt: Date
    public init(metric: String, value: JSONValue, unit: String?, observedAt: Date) {
        self.metric = metric; self.value = value; self.unit = unit; self.observedAt = observedAt
    }
}

public struct Observation: Codable, Sendable, Equatable {
    public var id: String
    public var sourceID: String
    public var metric: String
    public var value: JSONValue
    public var unit: String?
    public var observedAt: Date
    public var fetchedAt: Date
}

public struct LiveReading: Sendable {
    public var source: LiveSource
    public var observation: Observation?
    public var freshness: Freshness
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
}

public struct SourceStatus: Sendable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var lastErrorWasConnectivity: Bool
}

public enum FreshnessPolicy {
    public static func evaluate(source: LiveSource, status: SourceStatus?, latestObservedAt: Date?,
                                streaming: Bool = false, now: Date = Date()) -> Freshness {
        guard source.enabled else { return .disabled }
        guard let observed = latestObservedAt else { return .unavailable }
        let lastSuccess = status?.lastSuccess ?? observed
        let failingNow = (status?.lastAttempt ?? .distantPast) > lastSuccess && status?.lastError != nil
        if failingNow && status?.lastErrorWasConnectivity == true { return .offline }
        let age = now.timeIntervalSince(max(observed, lastSuccess))
        if failingNow || age > source.maxAgeSeconds { return .stale }
        return streaming ? .live : .fresh
    }
}

// MARK: - Connectors

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum ConnectorError: Error, CustomStringConvertible {
    case unreachable(String)
    case http(Int)
    case badResponse(String)
    case misconfigured(String)

    public var description: String {
        switch self {
        case .unreachable(let m): return "unreachable: \(m)"
        case .http(let c): return "HTTP \(c)"
        case .badResponse(let m): return "bad response: \(m)"
        case .misconfigured(let m): return "misconfigured: \(m)"
        }
    }

    public var isConnectivity: Bool { if case .unreachable = self { return true }; return false }

    static func classify(_ error: Error) -> ConnectorError {
        if let e = error as? ConnectorError { return e }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return .unreachable(u.localizedDescription)
            default: return .badResponse(u.localizedDescription)
            }
        }
        return .unreachable(String(describing: error))
    }
}

/// A connector turns an external system into normalized observations stored locally.
public protocol LiveConnector: Sendable {
    var id: String { get }
    /// Human-readable statement of exactly what leaves the household when fetching.
    func disclosure(for source: LiveSource) -> String
    func fetch(source: LiveSource, credential: String?) async throws -> [ObservationDraft]
}

/// Weather from Open-Meteo (https://open-meteo.com). No account, no API key, no cookies.
/// Only a coarsened coordinate (2 decimals ≈ 1 km) leaves the device.
public struct OpenMeteoConnector: LiveConnector {
    public let id = "open-meteo"
    public var baseURL: URL
    public var http: HTTPClient

    public init(baseURL: URL = URL(string: "https://api.open-meteo.com")!, http: HTTPClient = URLSessionHTTPClient()) {
        self.baseURL = baseURL; self.http = http
    }

    public static func makeSource(name: String, location: GeoPoint, entityID: String?) -> LiveSource {
        let coarse = location.coarsened(decimals: 2)
        return LiveSource(connector: "open-meteo", name: name, entityID: entityID,
                          config: ["latitude": String(coarse.latitude), "longitude": String(coarse.longitude)],
                          maxAgeSeconds: 3 * 3600)
    }

    public func disclosure(for source: LiveSource) -> String {
        "Sends approximate location (\(source.config["latitude"] ?? "?"), \(source.config["longitude"] ?? "?")) to api.open-meteo.com. No household records, media or identity."
    }

    static let variables = ["temperature_2m", "apparent_temperature", "relative_humidity_2m", "precipitation", "weather_code", "wind_speed_10m", "wind_gusts_10m"]

    public func fetch(source: LiveSource, credential: String?) async throws -> [ObservationDraft] {
        guard let lat = source.config["latitude"], let lon = source.config["longitude"] else {
            throw ConnectorError.misconfigured("latitude/longitude required")
        }
        var comps = URLComponents(url: baseURL.appendingPathComponent("v1/forecast"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: lat),
            URLQueryItem(name: "longitude", value: lon),
            URLQueryItem(name: "current", value: Self.variables.joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        let (data, status): (Data, Int)
        do { (data, status) = try await http.get(comps.url!, headers: ["Accept": "application/json"]) }
        catch { throw ConnectorError.classify(error) }
        guard status == 200 else { throw status >= 500 ? ConnectorError.unreachable("HTTP \(status)") : ConnectorError.http(status) }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [ObservationDraft] {
        guard case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let current)? = root["current"],
              let time = current["time"]?.stringValue else {
            throw ConnectorError.badResponse("missing current block")
        }
        let units: [String: JSONValue]
        if case .object(let u)? = root["current_units"] { units = u } else { units = [:] }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let observedAt = fmt.date(from: time) else { throw ConnectorError.badResponse("bad time \(time)") }
        return variables.compactMap { v in
            guard let value = current[v], value != .null else { return nil }
            return ObservationDraft(metric: v, value: value, unit: units[v]?.stringValue, observedAt: observedAt)
        }
    }
}

// MARK: - Credentials

/// Connector secrets live here (Keychain on Apple), never in records, logs, prompts or exports.
public protocol CredentialStore: Sendable {
    func secret(for ref: String) throws -> String?
    func setSecret(_ secret: String, for ref: String) throws
    func removeSecret(for ref: String) throws
}

public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var secrets: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func secret(for ref: String) throws -> String? { lock.lock(); defer { lock.unlock() }; return secrets[ref] }
    public func setSecret(_ secret: String, for ref: String) throws { lock.lock(); secrets[ref] = secret; lock.unlock() }
    public func removeSecret(for ref: String) throws { lock.lock(); secrets[ref] = nil; lock.unlock() }
}

// MARK: - Service

public final class LiveDataService: @unchecked Sendable {
    unowned let store: HearthStore
    private var connectors: [String: LiveConnector] = [:]
    private let lock = NSLock()
    public var credentials: CredentialStore = MemoryCredentialStore()

    init(store: HearthStore) {
        self.store = store
        register(OpenMeteoConnector())
    }

    public func register(_ connector: LiveConnector) {
        lock.lock(); connectors[connector.id] = connector; lock.unlock()
    }

    func connector(_ id: String) -> LiveConnector? { lock.lock(); defer { lock.unlock() }; return connectors[id] }

    public func sources() throws -> [LiveSource] { try store.all(LiveSource.self) }

    public enum RefreshOutcome: Sendable {
        case updated(Int)
        case failed(String, connectivity: Bool)
        case skippedDisabled
    }

    /// Fetches from the source. On failure the previous observations are kept and the
    /// failure is recorded so freshness becomes OFFLINE or STALE.
    @discardableResult
    public func refresh(_ source: LiveSource, now: Date = Date()) async -> RefreshOutcome {
        guard source.enabled else { return .skippedDisabled }
        guard let connector = connector(source.connector) else {
            recordStatus(source.id, attempt: now, success: nil, error: ConnectorError.misconfigured("no connector \(source.connector)"))
            return .failed("no connector \(source.connector)", connectivity: false)
        }
        do {
            let credential = try source.credentialRef.flatMap { try credentials.secret(for: $0) }
            let drafts = try await connector.fetch(source: source, credential: credential)
            let key = try store.keys.key(.observations)
            try store.db.transaction {
                for d in drafts {
                    let exists = try store.db.query("SELECT 1 FROM observations WHERE source_id = ? AND metric = ? AND observed_at = ?",
                                                    [.text(source.id), .text(d.metric), .double(d.observedAt.timeIntervalSince1970)])
                    if !exists.isEmpty { continue }
                    let obsID = HearthIDs.new()
                    let payload = try Sealer.sealJSON(ObservationPayload(value: d.value, unit: d.unit), key: key, aad: Data(obsID.utf8))
                    try store.db.execute("INSERT INTO observations(observation_id, source_id, metric, observed_at, fetched_at, sealed_value) VALUES (?, ?, ?, ?, ?, ?)",
                                         [.text(obsID), .text(source.id), .text(d.metric), .double(d.observedAt.timeIntervalSince1970),
                                          .double(now.timeIntervalSince1970), .blob(payload)])
                }
            }
            recordStatus(source.id, attempt: now, success: now, error: nil)
            return .updated(drafts.count)
        } catch {
            let classified = ConnectorError.classify(error)
            recordStatus(source.id, attempt: now, success: nil, error: classified)
            return .failed(classified.description, connectivity: classified.isConnectivity)
        }
    }

    public func refreshAll(now: Date = Date()) async -> [String: RefreshOutcome] {
        var out: [String: RefreshOutcome] = [:]
        for s in (try? sources()) ?? [] { out[s.id] = await refresh(s, now: now) }
        return out
    }

    private func recordStatus(_ sourceID: String, attempt: Date, success: Date?, error: ConnectorError?) {
        try? store.db.execute("""
            INSERT INTO source_status(source_id, last_attempt, last_success, last_error, last_error_kind) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(source_id) DO UPDATE SET last_attempt = excluded.last_attempt,
                last_success = COALESCE(excluded.last_success, source_status.last_success),
                last_error = excluded.last_error, last_error_kind = excluded.last_error_kind
            """, [.text(sourceID), .double(attempt.timeIntervalSince1970), success.map { .double($0.timeIntervalSince1970) } ?? .null,
                  .optionalText(error?.description), .optionalText(error.map { $0.isConnectivity ? "connectivity" : "other" })])
    }

    public func status(_ sourceID: String) throws -> SourceStatus? {
        guard let row = try store.db.query("SELECT * FROM source_status WHERE source_id = ?", [.text(sourceID)]).first else { return nil }
        return SourceStatus(lastAttempt: row.double("last_attempt").map(Date.init(timeIntervalSince1970:)),
                            lastSuccess: row.double("last_success").map(Date.init(timeIntervalSince1970:)),
                            lastError: row.string("last_error"),
                            lastErrorWasConnectivity: row.string("last_error_kind") == "connectivity")
    }

    struct ObservationPayload: Codable { var value: JSONValue; var unit: String? }

    public func observations(sourceID: String, metric: String? = nil, limit: Int = 500) throws -> [Observation] {
        var sql = "SELECT * FROM observations WHERE source_id = ?"
        var params: [SQLValue] = [.text(sourceID)]
        if let metric { sql += " AND metric = ?"; params.append(.text(metric)) }
        sql += " ORDER BY observed_at DESC LIMIT \(limit)"
        let key = try store.keys.key(.observations)
        return try store.db.query(sql, params).map { row in
            let id = row.string("observation_id") ?? ""
            let p = try Sealer.openJSON(ObservationPayload.self, row.data("sealed_value") ?? Data(), key: key, aad: Data(id.utf8))
            return Observation(id: id, sourceID: sourceID, metric: row.string("metric") ?? "", value: p.value, unit: p.unit,
                               observedAt: Date(timeIntervalSince1970: row.double("observed_at") ?? 0),
                               fetchedAt: Date(timeIntervalSince1970: row.double("fetched_at") ?? 0))
        }
    }

    /// Latest value per metric with freshness. Works fully offline.
    public func readings(for source: LiveSource, now: Date = Date()) throws -> [LiveReading] {
        let status = try status(source.id)
        var latest: [String: Observation] = [:]
        for o in try observations(sourceID: source.id, limit: 200) where latest[o.metric] == nil { latest[o.metric] = o }
        if latest.isEmpty {
            return [LiveReading(source: source, observation: nil,
                                freshness: FreshnessPolicy.evaluate(source: source, status: status, latestObservedAt: nil, now: now),
                                lastAttempt: status?.lastAttempt, lastSuccess: status?.lastSuccess, lastError: status?.lastError)]
        }
        return latest.values.sorted { $0.metric < $1.metric }.map { o in
            LiveReading(source: source, observation: o,
                        freshness: FreshnessPolicy.evaluate(source: source, status: status, latestObservedAt: o.fetchedAt, now: now),
                        lastAttempt: status?.lastAttempt, lastSuccess: status?.lastSuccess, lastError: status?.lastError)
        }
    }
}
