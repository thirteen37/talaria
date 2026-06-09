import Foundation

public struct HermesProfileInfo: Equatable, Sendable, Identifiable {
    public let name: String
    /// True for the default profile (`~/.hermes`), which Hermes conventionally
    /// names `default`. Set from an explicit `Default` column / marker, or
    /// inferred from the name.
    public let isDefault: Bool
    /// Optional runtime status (`running`, `stopped`, …) when the CLI surfaces
    /// one; nil otherwise.
    public let status: String?
    /// Configured model for the profile (e.g. `anthropic/claude-sonnet-4.6`),
    /// surfaced by the dashboard's `GET /api/profiles`. Nil when unknown.
    public let model: String?

    public var id: String { name }

    public init(
        name: String,
        isDefault: Bool,
        status: String? = nil,
        model: String? = nil
    ) {
        self.name = name
        self.isDefault = isDefault
        self.status = status
        self.model = model
    }
}

public enum HermesProfiles {
    /// Conventional name of the default profile (lives at `~/.hermes`).
    public static let defaultProfileName = "default"

    /// Global `-p <name>` flag tokens that scope a `hermes` invocation to a
    /// named profile, or empty for the default profile (`nil`/empty/`default`
    /// all yield no `-p`, which is what the window's shared dashboard already
    /// serves). Used for a local argv where no shell quoting is applied —
    /// `[hermesPath] + cliFlag(name) + ["acp"]` and friends.
    public static func cliFlag(_ name: String?) -> [String] {
        guard let name, !name.isEmpty, name != defaultProfileName else { return [] }
        return ["-p", name]
    }

    /// Like ``cliFlag(_:)`` but single-quotes the name for a remote shell
    /// command line, matching how the hermes path and env vars are quoted.
    public static func remoteCLIFlag(_ name: String?) -> [String] {
        guard let name, !name.isEmpty, name != defaultProfileName else { return [] }
        return ["-p", ShellQuoting.shellQuote(name)]
    }

    /// Profiles that drive the window's Hermes-profile switcher, sourced solely
    /// from the dashboard `/api/profiles` route. The dashboard reports clean
    /// names and a structured default flag, so this never parses the decorated
    /// CLI `profile list` table (whose default-marker glyph would otherwise leak
    /// into the menu — the bug this path replaces).
    ///
    /// Returns a default-only list when the dashboard client isn't online yet or
    /// the call fails — the switcher then shows a `default`-only menu. The caller
    /// re-runs this once `dashboardClient` becomes available to upgrade to the
    /// live list.
    public static func selectorProfiles(client: DashboardClient?) async -> [HermesProfileInfo] {
        guard let client else { return defaultOnly }
        do {
            return try await client.listProfiles().map {
                HermesProfileInfo(name: $0.name, isDefault: $0.isDefault, status: nil)
            }
        } catch {
            return defaultOnly
        }
    }

    /// The default-only state for the switcher: a single `default` row, used
    /// while the dashboard isn't online yet or after a failed read. The sidebar
    /// shows it as a `default`-only menu.
    private static var defaultOnly: [HermesProfileInfo] {
        [HermesProfileInfo(name: defaultProfileName, isDefault: true, status: nil)]
    }
}
