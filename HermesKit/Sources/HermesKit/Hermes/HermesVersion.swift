import Foundation

public struct HermesVersion: Codable, Comparable, Equatable, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionText = trimmed.firstMatch(of: /(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z0-9.\-]+))?/)
        guard let versionText else {
            return nil
        }
        self.major = Int(versionText.1) ?? 0
        self.minor = Int(versionText.2) ?? 0
        self.patch = Int(versionText.3) ?? 0
        self.prerelease = versionText.4.map(String.init)
    }

    public static func < (lhs: HermesVersion, rhs: HermesVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case let (lhs?, rhs?):
            return comparePrerelease(lhs, rhs) == .orderedAscending
        }
    }

    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsIdentifiers = lhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let rhsIdentifiers = rhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        for index in 0..<min(lhsIdentifiers.count, rhsIdentifiers.count) {
            let result = comparePrereleaseIdentifier(lhsIdentifiers[index], rhsIdentifiers[index])
            if result != .orderedSame {
                return result
            }
        }

        if lhsIdentifiers.count == rhsIdentifiers.count {
            return .orderedSame
        }
        return lhsIdentifiers.count < rhsIdentifiers.count ? .orderedAscending : .orderedDescending
    }

    private static func comparePrereleaseIdentifier(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsNumber = prereleaseNumber(lhs)
        let rhsNumber = prereleaseNumber(rhs)

        switch (lhsNumber, rhsNumber) {
        case let (lhs?, rhs?):
            if lhs.count != rhs.count {
                return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
            }
            if lhs != rhs {
                return lhs < rhs ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        case (_?, nil):
            return .orderedAscending
        case (nil, _?):
            return .orderedDescending
        case (nil, nil):
            if lhs == rhs {
                return .orderedSame
            }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        }
    }

    private static func prereleaseNumber(_ identifier: String) -> String? {
        guard !identifier.isEmpty, identifier.allSatisfy(\.isNumber) else {
            return nil
        }
        let trimmed = identifier.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}
