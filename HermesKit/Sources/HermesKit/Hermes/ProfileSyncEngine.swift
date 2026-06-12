import Foundation

/// The four resources the sync surface reads per profile. Each fails
/// independently so one read error degrades only its own section.
public enum SyncResource: String, Equatable, Sendable, CaseIterable {
    case skills
    case skillsCheck
    case config
    case env
}

/// Everything read for one profile. The plaintext env values live here, in
/// memory only — the drift items downstream carry redacted previews.
public struct ProfileSyncSnapshot: Equatable, Sendable {
    public let profileName: String
    public let skills: [InstalledHubSkill]
    public let updateStatuses: [SkillUpdateStatus]
    public let config: JSONValue?
    public let env: [EnvFileEntry]?

    public init(
        profileName: String,
        skills: [InstalledHubSkill],
        updateStatuses: [SkillUpdateStatus],
        config: JSONValue?,
        env: [EnvFileEntry]?
    ) {
        self.profileName = profileName
        self.skills = skills
        self.updateStatuses = updateStatuses
        self.config = config
        self.env = env
    }
}

/// Result of a fetch sweep: the per-profile snapshots plus the per-profile,
/// per-resource read failures (each resource isolated).
public struct ProfileSyncFetchResult: Sendable {
    public var snapshots: [String: ProfileSyncSnapshot]
    public var failures: [String: [SyncResource: String]]

    public init(
        snapshots: [String: ProfileSyncSnapshot] = [:],
        failures: [String: [SyncResource: String]] = [:]
    ) {
        self.snapshots = snapshots
        self.failures = failures
    }
}

/// One skill mutation to push into a target profile.
public enum SkillPushAction: Equatable, Sendable {
    case install(identifier: String, name: String)
    case update(name: String)

    public var displayName: String {
        switch self {
        case let .install(_, name): return name
        case let .update(name): return name
        }
    }
}

public struct SkillPushOutcome: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case install, update }
    public let name: String
    public let kind: Kind
    /// nil on success; the surfaced reason otherwise (install/update continues
    /// past a failure, including `operationRejected`).
    public let error: String?

    public var id: String { name }
    public var succeeded: Bool { error == nil }

    public init(name: String, kind: Kind, error: String?) {
        self.name = name
        self.kind = kind
        self.error = error
    }
}

public struct ConfigPushOutcome: Equatable, Sendable {
    /// The dotpaths in the pushed batch (the PUT is atomic — one outcome).
    public let dotpaths: [String]
    public let error: String?

    public var succeeded: Bool { error == nil }

    public init(dotpaths: [String], error: String?) {
        self.dotpaths = dotpaths
        self.error = error
    }
}

public struct EnvPushOutcome: Equatable, Sendable, Identifiable {
    public let key: String
    public let error: String?

    public var id: String { key }
    public var succeeded: Bool { error == nil }

    public init(key: String, error: String?) {
        self.key = key
        self.error = error
    }
}

/// Profile-scoped admin runner factory: maps a Hermes profile name to a runner
/// that prepends `-p <name>` (default omits the flag).
public typealias RunnerProvider = @Sendable (String) -> any HermesAdminRunning

/// Orchestrates the read (drift) and write (push) sides of cross-profile sync.
/// UI-free and pure orchestration: it never spawns dashboards or resolves file
/// paths itself — the caller injects the runner factory, the config/env reader
/// closures (built from ``HermesConfigReader`` / ``HermesEnvFileReader``), and,
/// for pushes, a profile-scoped ``DashboardClient`` obtained through the
/// harness's client seam.
public struct ProfileSyncEngine: Sendable {
    public init() {}

    /// Wraps a single unscoped base runner into a per-profile scoped factory —
    /// the production `RunnerProvider`. For the default profile the wrapper is
    /// transparent (no `-p`).
    public static func scopedRunnerProvider(base: any HermesAdminRunning) -> RunnerProvider {
        { name in ProfileScopedHermesAdminRunner(inner: base, hermesProfileName: name) }
    }

    // MARK: - Fetch

    /// Reads skills (+ update status), config, and env for every profile, with a
    /// bounded number running concurrently. Per-profile and per-resource failures
    /// are isolated: a config read error for one profile doesn't stop its skills
    /// drift or any other profile. `skills check` is skipped for the default
    /// profile and whenever a profile has no hub-managed skills.
    public func fetchSnapshots(
        profiles: [String],
        runnerProvider: @escaping RunnerProvider,
        configReader: @escaping @Sendable (String) async throws -> JSONValue,
        envReader: @escaping @Sendable (String) async throws -> [EnvFileEntry],
        maxConcurrent: Int = 3
    ) async -> ProfileSyncFetchResult {
        var result = ProfileSyncFetchResult()
        let cap = max(1, maxConcurrent)

        await withTaskGroup(of: (String, ProfileSyncSnapshot, [SyncResource: String]).self) { group in
            var iterator = profiles.makeIterator()

            // Seed up to `cap` profile tasks, then refill one-for-one as each
            // completes — a sliding window that bounds concurrency at `cap`.
            for _ in 0..<cap {
                guard let name = iterator.next() else { break }
                group.addTask {
                    await self.fetchOne(name: name, runnerProvider: runnerProvider, configReader: configReader, envReader: envReader)
                }
            }

            while let (name, snapshot, failures) = await group.next() {
                result.snapshots[name] = snapshot
                if !failures.isEmpty { result.failures[name] = failures }
                if let nextName = iterator.next() {
                    group.addTask {
                        await self.fetchOne(name: nextName, runnerProvider: runnerProvider, configReader: configReader, envReader: envReader)
                    }
                }
            }
        }

        return result
    }

    private func fetchOne(
        name: String,
        runnerProvider: @escaping RunnerProvider,
        configReader: @escaping @Sendable (String) async throws -> JSONValue,
        envReader: @escaping @Sendable (String) async throws -> [EnvFileEntry]
    ) async -> (String, ProfileSyncSnapshot, [SyncResource: String]) {
        let runner = runnerProvider(name)
        var failures: [SyncResource: String] = [:]

        var skills: [InstalledHubSkill] = []
        do {
            skills = try await HermesSkillsHub.listInstalled(runner: runner)
        } catch {
            failures[.skills] = error.localizedDescription
        }

        // `skills check` is comparatively slow; skip it for the default profile
        // (it's the source, never a push target for updates) and when the
        // profile has no hub-managed skills to check.
        var updateStatuses: [SkillUpdateStatus] = []
        if name != HermesProfiles.defaultProfileName, skills.contains(where: \.isHubManaged) {
            do {
                updateStatuses = try await HermesSkillsHub.checkUpdates(runner: runner)
            } catch {
                failures[.skillsCheck] = error.localizedDescription
            }
        }

        var config: JSONValue?
        do {
            config = try await configReader(name)
        } catch {
            failures[.config] = error.localizedDescription
        }

        var env: [EnvFileEntry]?
        do {
            env = try await envReader(name)
        } catch {
            failures[.env] = error.localizedDescription
        }

        let snapshot = ProfileSyncSnapshot(
            profileName: name,
            skills: skills,
            updateStatuses: updateStatuses,
            config: config,
            env: env
        )
        return (name, snapshot, failures)
    }

    // MARK: - Push: skills

    /// Installs/updates skills in `profileName`, **sequentially** (hermes mutates
    /// the profile's skills dir), continuing past per-item failures (including
    /// `HermesSkillsHubError.operationRejected`). Honors cancellation between
    /// items.
    public func pushSkills(
        actions: [SkillPushAction],
        toProfile profileName: String,
        runnerProvider: @escaping RunnerProvider
    ) async -> [SkillPushOutcome] {
        let runner = runnerProvider(profileName)
        var outcomes: [SkillPushOutcome] = []
        for action in actions {
            if Task.isCancelled { break }
            do {
                switch action {
                case let .install(identifier, name):
                    _ = try await HermesSkillsHub.install(runner: runner, identifier: identifier)
                    outcomes.append(SkillPushOutcome(name: name, kind: .install, error: nil))
                case let .update(name):
                    _ = try await HermesSkillsHub.update(runner: runner, name: name)
                    outcomes.append(SkillPushOutcome(name: name, kind: .update, error: nil))
                }
            } catch {
                let kind: SkillPushOutcome.Kind = { if case .install = action { return .install } else { return .update } }()
                outcomes.append(SkillPushOutcome(name: action.displayName, kind: kind, error: error.localizedDescription))
            }
        }
        return outcomes
    }

    // MARK: - Push: config

    /// Re-GETs the target's current config, applies the structured edits
    /// non-destructively, and PUTs the merged whole document. Re-GET-before-merge
    /// guarantees a PUT never clobbers keys the editor didn't surface. The PUT is
    /// atomic, so the batch produces one outcome.
    public func pushConfig(edits: [String: ConfigValue], client: DashboardClient) async -> ConfigPushOutcome {
        let dotpaths = edits.keys.sorted()
        guard !edits.isEmpty else { return ConfigPushOutcome(dotpaths: [], error: nil) }
        do {
            let fresh = try await client.getConfig()
            let merged = ProfileConfigForm.merged(into: fresh, edits: edits)
            try await client.updateConfig(merged)
            return ConfigPushOutcome(dotpaths: dotpaths, error: nil)
        } catch {
            return ConfigPushOutcome(dotpaths: dotpaths, error: error.localizedDescription)
        }
    }

    // MARK: - Push: env

    /// Copies each `(key, value)` into the target via `PUT /api/env`,
    /// **sequentially** with per-key outcomes, continuing past a rejection (e.g.
    /// a managed-key 4xx). Honors cancellation between keys.
    public func pushEnv(items: [(key: String, value: String)], client: DashboardClient) async -> [EnvPushOutcome] {
        var outcomes: [EnvPushOutcome] = []
        for item in items {
            if Task.isCancelled { break }
            do {
                try await client.setEnvVar(key: item.key, value: item.value)
                outcomes.append(EnvPushOutcome(key: item.key, error: nil))
            } catch {
                outcomes.append(EnvPushOutcome(key: item.key, error: error.localizedDescription))
            }
        }
        return outcomes
    }
}
