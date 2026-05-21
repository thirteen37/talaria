import Foundation

public enum HermesCapability: String, CaseIterable, Codable, Sendable {
    case acp
    case permissions
    case diffs
    case cronCRUD
    case updateCheck
}

public struct CapabilityTable: Sendable {
    public let minimumVersions: [HermesCapability: HermesVersion]

    public init(minimumVersions: [HermesCapability: HermesVersion] = CapabilityTable.defaults) {
        self.minimumVersions = minimumVersions
    }

    public func supports(_ capability: HermesCapability, version: HermesVersion?) -> Bool {
        guard let required = minimumVersions[capability], let version else {
            return false
        }
        return version >= required
    }

    public static let defaults: [HermesCapability: HermesVersion] = [
        .acp: HermesVersion(major: 0, minor: 0, patch: 0),
        .permissions: HermesVersion(major: 0, minor: 0, patch: 0),
        .diffs: HermesVersion(major: 0, minor: 0, patch: 0),
        .cronCRUD: HermesVersion(major: 0, minor: 0, patch: 0),
        .updateCheck: HermesVersion(major: 0, minor: 0, patch: 0),
    ]
}
