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
            return lhs < rhs
        }
    }
}
