import Foundation

/// Identity-based permissions. Permissions attach to people, not devices; a device acts
/// as the identity that enrolled it.
public enum AccessPolicy {
    public static func canRead(_ identity: Identity, _ record: RecordEnvelope) -> Bool {
        // Identity records are visible to everyone in the household so names can render.
        if record.kind == .identity || record.kind == .household { return true }
        switch identity.role {
        case .owner:
            return true
        case .adult:
            if let acl = record.acl { return acl.contains(identity.id) }
            return true
        case .child:
            if let acl = record.acl { return acl.contains(identity.id) }
            return record.sensitivity == .normal
        case .guest:
            if let acl = record.acl { return acl.contains(identity.id) }
            return record.sensitivity == .normal && record.fields["guestVisible"]?.boolValue == true
        case .emergencyAccess:
            return record.emergency && record.sensitivity != .restricted
        }
    }

    public static func canWrite(_ identity: Identity, _ record: RecordEnvelope?) -> Bool {
        switch identity.role {
        case .owner: return true
        case .adult: return record.map { canRead(identity, $0) } ?? true
        case .child: return record.map { canRead(identity, $0) && $0.sensitivity == .normal } ?? true
        case .guest, .emergencyAccess: return false
        }
    }

    public static func canManageDevices(_ identity: Identity) -> Bool { identity.role == .owner }
}

public enum AccessError: Error, Equatable {
    case notPermitted(String)
    case deviceRevoked(String)
}

/// Default sensitivity for records in protected categories. A financial or identity record
/// is restricted (vault + biometrics) unless the user explicitly lowers it.
public enum SensitivityPolicy {
    public static let vaultCategories: Set<SensitiveCategory> = [.financial, .identity, .security, .network, .insurance]

    public static func minimumSensitivity(for categories: [SensitiveCategory]) -> Sensitivity {
        if categories.contains(where: vaultCategories.contains) { return .restricted }
        if categories.contains(.medical) || categories.contains(.familyPrivate) { return .private }
        return .normal
    }
}
