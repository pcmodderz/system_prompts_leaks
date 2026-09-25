import Crypto
import _CryptoExtras
import Foundation

/// Everything a new household device needs, created on an already-trusted device by an
/// owner. Transferred device-to-device (AirDrop, local network, QR sequence, USB) sealed
/// with a one-time pairing code the owner reads out. No Hearth server is involved.
public struct Enrollment: Codable, Sendable {
    public var householdID: String
    public var device: DeviceRecord
    public var householdKey: Data
    /// Only included when the new device's identity may open restricted records.
    public var vaultKey: Data?
    /// Household, identity and device records so the new device can verify authorship
    /// before its first full sync.
    public var bootstrapOps: [Operation]
}

public struct SealedEnrollment: Codable, Sendable {
    public var salt: Data
    public var sealed: Data
}

public enum PairingCode {
    /// 12 characters from an unambiguous alphabet (~60 bits), shown as XXXX-XXXX-XXXX.
    public static func generate() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let raw = (0..<12).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
        return stride(from: 0, to: 12, by: 4).map { String(raw[$0..<$0 + 4]) }.joined(separator: "-")
    }

    static func key(code: String, salt: Data) throws -> SymmetricKey {
        let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
        return try KDF.Scrypt.deriveKey(from: Data(normalized.utf8), salt: salt, outputByteCount: 32,
                                        rounds: 1 << 15, blockSize: 8, parallelism: 1)
    }
}

public extension HearthStore {
    /// Owner-only: enroll a new device for `identityID` and seal the package with `pairingCode`.
    func enrollDevice(name: String, platform: String, for identityID: String, pairingCode: String) throws -> SealedEnrollment {
        guard AccessPolicy.canManageDevices(try currentIdentity()) else { throw AccessError.notPermitted("enroll device") }
        guard let identity = try fetch(Identity.self, id: identityID) else { throw HearthStoreError.recordNotFound(identityID) }
        let device = DeviceRecord(id: HearthIDs.new(), name: name, platform: platform, ownerIdentity: identityID)
        try save(device, provenance: .manual)

        let bootstrapIDs = Set([householdID] + (try allEnvelopes(kind: .identity).map(\.id)) + (try allEnvelopes(kind: .device).map(\.id)))
        let bootstrap = try operations().filter { bootstrapIDs.contains($0.recordID) && $0.keyClass == .household }
        let mayOpenVault = identity.role == .owner || identity.role == .adult
        let enrollment = Enrollment(
            householdID: householdID, device: device,
            householdKey: try keys.householdRoot().withUnsafeBytes { Data($0) },
            // The vault key is only shared if the owner has unlocked the vault (Face ID) for this.
            vaultKey: mayOpenVault ? (try? keys.vault())?.withUnsafeBytes { Data($0) } : nil,
            bootstrapOps: bootstrap)
        var salt = Data(count: 16)
        for i in 0..<16 { salt[i] = UInt8.random(in: 0...255) }
        let sealed = try Sealer.sealJSON(enrollment, key: PairingCode.key(code: pairingCode, salt: salt))
        return SealedEnrollment(salt: salt, sealed: sealed)
    }

    static func openEnrollment(_ sealed: SealedEnrollment, pairingCode: String) throws -> Enrollment {
        try Sealer.openJSON(Enrollment.self, sealed.sealed, key: PairingCode.key(code: pairingCode, salt: sealed.salt))
    }
}

/// Apple Data Protection classes for Hearth's files. No-op on platforms without it.
public enum DataProtection {
    public enum Level: Sendable {
        /// Database: readable while unlocked; stays writable if already open when the device
        /// locks (so a background refresh can finish).
        case database
        /// Media and backups: unreadable whenever the device is locked.
        case media
    }

    public static func protect(_ url: URL, level: Level) {
        #if os(iOS) || os(watchOS) || os(visionOS) || os(tvOS)
        let type: FileProtectionType = level == .media ? .complete : .completeUnlessOpen
        try? FileManager.default.setAttributes([.protectionKey: type], ofItemAtPath: url.path)
        #endif
    }
}
