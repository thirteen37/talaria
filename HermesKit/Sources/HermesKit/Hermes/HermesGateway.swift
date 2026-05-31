import Foundation

public enum HermesGatewayError: Error, Equatable, Sendable, LocalizedError {
    case commandUnavailable(String)
    case commandFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .commandUnavailable(let detail):
            return "Gateway command unavailable in this Hermes version: \(detail)"
        case .commandFailed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "hermes gateway failed (exit \(code))" : trimmed
        }
    }
}

/// CLI lifecycle builders for `hermes gateway …`. Status is read from the
/// dashboard `/api/status` route (`DashboardStatus`'s gateway fields), so there
/// is no `status`/`list` builder here — only the writes, which have no
/// dashboard HTTP route and go through the admin runner (the same path Tools
/// and Doctor use). The runner is a `ProfileScopedHermesAdminRunner`, so every
/// verb is auto-scoped to the active profile (`-p <name>`).
///
/// `install` / `uninstall` take no interactive-confirmation flags (verified
/// against `hermes gateway {install,uninstall} --help`: install offers only
/// `--force` / `--system` / `--run-as-user`, uninstall only `--system`; neither
/// prompts), so the bare verb is non-interactive. The UI supplies its own
/// destructive confirmation before calling `uninstall`.
public enum HermesGateway {
    public static func start(runner: HermesAdminRunning) async throws {
        try await run(runner: runner, verb: "start")
    }

    public static func stop(runner: HermesAdminRunning) async throws {
        try await run(runner: runner, verb: "stop")
    }

    public static func restart(runner: HermesAdminRunning) async throws {
        try await run(runner: runner, verb: "restart")
    }

    public static func install(runner: HermesAdminRunning) async throws {
        try await run(runner: runner, verb: "install")
    }

    public static func uninstall(runner: HermesAdminRunning) async throws {
        try await run(runner: runner, verb: "uninstall")
    }

    private static func run(runner: HermesAdminRunning, verb: String) async throws {
        let result = try await runner.run(HermesAdminCommand(arguments: ["gateway", verb]))
        try ensureSuccess(result)
    }

    static func ensureSuccess(_ result: HermesAdminResult) throws {
        guard result.exitCode != 0 else { return }
        let stderr = result.stderr.lowercased()
        // Mirror HermesTools/HermesProfiles: match only command-shape failures so
        // we don't mislabel `env: hermes: No such file or directory` (a PATH
        // failure) as "version too old".
        if stderr.contains("unknown command")
            || stderr.contains("no such command")
            || stderr.contains("no such subcommand") {
            throw HermesGatewayError.commandUnavailable(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw HermesGatewayError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
}
