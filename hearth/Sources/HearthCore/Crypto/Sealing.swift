import Crypto
import Foundation

public enum SealError: Error {
    case malformed
    case authenticationFailed
    case truncated
}

enum Sealer {
    /// AES-256-GCM, output is nonce || ciphertext || tag.
    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data = Data()) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = box.combined else { throw SealError.malformed }
        return combined
    }

    static func open(_ sealed: Data, key: SymmetricKey, aad: Data = Data()) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw SealError.authenticationFailed
        }
    }

    static func sealJSON<T: Encodable>(_ value: T, key: SymmetricKey, aad: Data = Data()) throws -> Data {
        try seal(HearthJSON.encoder.encode(value), key: key, aad: aad)
    }

    static func openJSON<T: Decodable>(_ type: T.Type, _ sealed: Data, key: SymmetricKey, aad: Data = Data()) throws -> T {
        try HearthJSON.decoder.decode(type, from: open(sealed, key: key, aad: aad))
    }
}

/// Streaming authenticated encryption for large files (video) so a 4 GB clip never has to
/// fit in memory. Format:
///
///     "HRTHBLOB" (8) | version u8 | chunkSize u32 BE | noncePrefix (8)
///     repeated: AES-GCM(ciphertext || tag) of each chunk
///
/// Each chunk's nonce is noncePrefix || counter(u32 BE). The header, counter and a
/// final-chunk flag are authenticated, so truncation, reordering and splicing are detected.
public enum ChunkedCipher {
    static let magic = Data("HRTHBLOB".utf8)
    static let version: UInt8 = 1
    public static let defaultChunkSize = 1 << 20
    static let tagSize = 16

    public static func encrypt(input: URL, output: URL, key: SymmetricKey, chunkSize: Int = defaultChunkSize) throws {
        guard let reader = InputStream(url: input) else { throw CocoaError(.fileReadNoSuchFile) }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        reader.open(); defer { reader.close() }

        var prefix = Data(count: 8)
        for i in 0..<8 { prefix[i] = UInt8.random(in: 0...255) }
        var header = magic
        header.append(version)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).bigEndian, Array.init))
        header.append(prefix)
        try writer.write(contentsOf: header)

        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var current = try readFully(reader, &buffer)
        var counter: UInt32 = 0
        while true {
            let next = current.count == chunkSize ? try readFully(reader, &buffer) : Data()
            let isFinal = next.isEmpty
            let sealed = try sealChunk(current, header: header, prefix: prefix, counter: counter, isFinal: isFinal, key: key)
            try writer.write(contentsOf: sealed)
            if isFinal { break }
            current = next
            counter += 1
        }
    }

    public static func decrypt(input: URL, key: SymmetricKey, consume: (Data) throws -> Void) throws {
        guard let reader = InputStream(url: input) else { throw CocoaError(.fileReadNoSuchFile) }
        reader.open(); defer { reader.close() }
        var headerBytes = [UInt8](repeating: 0, count: magic.count + 1 + 4 + 8)
        let header = try readFully(reader, &headerBytes)
        guard header.count == headerBytes.count, header.prefix(magic.count) == magic,
              header[header.startIndex + magic.count] == version else { throw SealError.malformed }
        let sizeBytes = header.subdata(in: (magic.count + 1)..<(magic.count + 5))
        let chunkSize = Int(sizeBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        let prefix = header.subdata(in: (magic.count + 5)..<header.count)

        var buffer = [UInt8](repeating: 0, count: chunkSize + 12 + tagSize)
        var counter: UInt32 = 0
        var current = try readFully(reader, &buffer)
        while true {
            guard !current.isEmpty else { throw SealError.truncated }
            let next = current.count == buffer.count ? try readFully(reader, &buffer) : Data()
            let isFinal = next.isEmpty
            let plain = try openChunk(current, header: header, prefix: prefix, counter: counter, isFinal: isFinal, key: key)
            try consume(plain)
            if isFinal { break }
            current = next
            counter += 1
        }
    }

    public static func decrypt(input: URL, output: URL, key: SymmetricKey) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        try decrypt(input: input, key: key) { try writer.write(contentsOf: $0) }
    }

    private static func nonce(_ prefix: Data, _ counter: UInt32) throws -> AES.GCM.Nonce {
        var n = prefix
        n.append(contentsOf: withUnsafeBytes(of: counter.bigEndian, Array.init))
        return try AES.GCM.Nonce(data: n)
    }

    private static func aad(_ header: Data, _ counter: UInt32, _ isFinal: Bool) -> Data {
        var a = header
        a.append(contentsOf: withUnsafeBytes(of: counter.bigEndian, Array.init))
        a.append(isFinal ? 1 : 0)
        return a
    }

    private static func sealChunk(_ chunk: Data, header: Data, prefix: Data, counter: UInt32, isFinal: Bool, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(chunk, using: key, nonce: nonce(prefix, counter), authenticating: aad(header, counter, isFinal))
        guard let combined = box.combined else { throw SealError.malformed }
        return combined
    }

    private static func openChunk(_ chunk: Data, header: Data, prefix: Data, counter: UInt32, isFinal: Bool, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: chunk)
            return try AES.GCM.open(box, using: key, authenticating: aad(header, counter, isFinal))
        } catch {
            throw SealError.authenticationFailed
        }
    }

    private static func readFully(_ stream: InputStream, _ buffer: inout [UInt8]) throws -> Data {
        var total = 0
        while total < buffer.count {
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                stream.read(ptr.baseAddress! + total, maxLength: ptr.count - total)
            }
            if n < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if n == 0 { break }
            total += n
        }
        return Data(buffer[0..<total])
    }
}

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    public static func sha256Hex(fileAt url: URL) throws -> String {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadNoSuchFile) }
        stream.open(); defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if n == 0 { break }
            hasher.update(data: buffer[0..<n])
        }
        return hasher.finalize().hexString
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Digest {
    var hexString: String { Array(self).hexString }
}

public enum HearthJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
