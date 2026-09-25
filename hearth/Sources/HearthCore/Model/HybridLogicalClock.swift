import Foundation

/// Hybrid logical clock timestamp. Totally ordered across devices, close to wall time,
/// and robust to devices whose clocks are wrong (e.g. a phone that was offline for a week).
///
/// Encoded as a fixed-width string so lexical order == causal/total order:
/// `000001727222222222-0000000003-<node>`
public struct HLC: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let millis: Int64
    public let counter: UInt32
    public let node: String

    public init(millis: Int64, counter: UInt32, node: String) {
        self.millis = millis
        self.counter = counter
        self.node = node
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 2).map(String.init)
        guard parts.count == 3, let m = Int64(parts[0]), let c = UInt32(parts[1]) else { return nil }
        self.init(millis: m, counter: c, node: parts[2])
    }

    public var description: String {
        String(format: "%018lld-%010u-", millis, counter) + node
    }

    public var date: Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

    public static func < (a: HLC, b: HLC) -> Bool {
        (a.millis, a.counter, a.node) < (b.millis, b.counter, b.node)
    }

    public static let zero = HLC(millis: 0, counter: 0, node: "")

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let v = HLC(s) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad HLC \(s)")) }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

public final class HybridClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last: HLC
    private let node: String
    private let wall: () -> Int64

    public init(node: String, last: HLC = .zero, wall: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.node = node
        self.last = last
        self.wall = wall
    }

    public func now() -> HLC {
        lock.lock(); defer { lock.unlock() }
        let w = wall()
        if w > last.millis {
            last = HLC(millis: w, counter: 0, node: node)
        } else {
            last = HLC(millis: last.millis, counter: last.counter + 1, node: node)
        }
        return last
    }

    /// Advance past a timestamp received from another device.
    public func observe(_ remote: HLC) {
        lock.lock(); defer { lock.unlock() }
        let w = wall()
        let m = max(w, last.millis, remote.millis)
        let c: UInt32
        if m == last.millis && m == remote.millis { c = max(last.counter, remote.counter) + 1 }
        else if m == last.millis { c = last.counter + 1 }
        else if m == remote.millis { c = remote.counter + 1 }
        else { c = 0 }
        last = HLC(millis: m, counter: c, node: node)
    }
}
