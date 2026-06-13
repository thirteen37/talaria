import Foundation

/// One env var that differs between the default profile's `.env` and a named
/// profile's `.env`. **Carries only redacted previews — never plaintext.** The
/// real secret stays in the in-memory snapshot and is read only at push/reveal
/// time, so an `Equatable`/debug dump of this item can't leak a credential.
public struct EnvDriftItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case missing
        case valueDiffers
    }

    public let key: String
    public let kind: Kind
    public let redactedDefaultValue: String
    public let redactedProfileValue: String?

    public var id: String { key }

    public init(key: String, kind: Kind, redactedDefaultValue: String, redactedProfileValue: String?) {
        self.key = key
        self.kind = kind
        self.redactedDefaultValue = redactedDefaultValue
        self.redactedProfileValue = redactedProfileValue
    }
}

/// An env key present only in the named profile — display-only (v1 never deletes
/// from a target). Redacted preview only.
public struct EnvExtraItem: Equatable, Sendable, Identifiable {
    public let key: String
    public let redactedValue: String

    public var id: String { key }

    public init(key: String, redactedValue: String) {
        self.key = key
        self.redactedValue = redactedValue
    }
}

/// Environment-level drift for one named profile relative to the default
/// profile's `.env`.
public struct ProfileEnvDrift: Equatable, Sendable {
    public let profileName: String
    /// Out-of-sync keys, in the default `.env`'s order.
    public let items: [EnvDriftItem]
    /// Keys present only in the named profile, display-only.
    public let extras: [EnvExtraItem]

    public init(profileName: String, items: [EnvDriftItem], extras: [EnvExtraItem]) {
        self.profileName = profileName
        self.items = items
        self.extras = extras
    }

    public var missingCount: Int { items.filter { $0.kind == .missing }.count }
    public var differingCount: Int { items.filter { $0.kind == .valueDiffers }.count }
    public var isInSync: Bool { items.isEmpty }
}

/// Computes env drift between the default profile (source of truth) and a named
/// profile, over parsed `.env` entries. Pure — plaintext values are passed in
/// but only their redacted previews leave this layer.
public enum ProfileEnvDriftPlanner {
    public static func drift(
        profileName: String,
        defaultEntries: [EnvFileEntry],
        profileEntries: [EnvFileEntry]
    ) -> ProfileEnvDrift {
        let profileByKey = Dictionary(
            profileEntries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first }
        )

        var items: [EnvDriftItem] = []
        for entry in defaultEntries where isValidKey(entry.key) {
            if let profileValue = profileByKey[entry.key] {
                if profileValue != entry.value {
                    items.append(EnvDriftItem(
                        key: entry.key,
                        kind: .valueDiffers,
                        redactedDefaultValue: redactEnvValue(entry.value),
                        redactedProfileValue: redactEnvValue(profileValue)
                    ))
                }
            } else {
                items.append(EnvDriftItem(
                    key: entry.key,
                    kind: .missing,
                    redactedDefaultValue: redactEnvValue(entry.value),
                    redactedProfileValue: nil
                ))
            }
        }

        let defaultKeys = Set(defaultEntries.map(\.key))
        let extras = profileEntries
            .filter { !defaultKeys.contains($0.key) }
            .map { EnvExtraItem(key: $0.key, redactedValue: redactEnvValue($0.value)) }

        return ProfileEnvDrift(profileName: profileName, items: items, extras: extras)
    }

    /// `^[A-Za-z_][A-Za-z0-9_]*$` — the server-side env-key constraint. Keys that
    /// fail it are excluded from push candidates because `PUT /api/env` rejects
    /// them.
    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        guard isLetter(first) || first == "_" else { return false }
        for scalar in key.unicodeScalars.dropFirst() {
            guard isLetter(scalar) || isDigit(scalar) || scalar == "_" else { return false }
        }
        return true
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        (s >= "A" && s <= "Z") || (s >= "a" && s <= "z")
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool {
        s >= "0" && s <= "9"
    }
}
