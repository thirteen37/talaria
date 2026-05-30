import Foundation

/// Wraps an inner ``HermesAdminRunning`` to scope every admin command to a
/// named Hermes profile via the global `-p <name>` flag, so Tools/Doctor and
/// the other admin surfaces operate on the window's active Hermes profile
/// rather than always the unscoped default install.
///
/// Two commands are passed through **unscoped**:
///   * the default profile (`name == default`) needs no flag — it's the
///     unscoped install the bare invocation already targets;
///   * `profile …` subcommands (notably `profile list`) must enumerate / act
///     across every profile, so scoping them to one would be wrong — and
///     future `profile` writes shouldn't be silently mis-scoped either.
///
/// `-p <name>` is a *global* flag, so it precedes the subcommand in the
/// argument vector (`-p work tools list`), matching the dashboard / ACP shape.
public struct ProfileScopedHermesAdminRunner: HermesAdminRunning {
    private let inner: any HermesAdminRunning
    private let hermesProfileName: String

    public init(inner: any HermesAdminRunning, hermesProfileName: String) {
        self.inner = inner
        self.hermesProfileName = hermesProfileName
    }

    public func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        try await inner.run(scoped(command))
    }

    public func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        inner.runStream(scoped(command))
    }

    private func scoped(_ command: HermesAdminCommand) -> HermesAdminCommand {
        guard hermesProfileName != HermesProfiles.defaultProfileName,
              command.arguments.first != "profile" else {
            return command
        }
        var scoped = command
        scoped.arguments = ["-p", hermesProfileName] + command.arguments
        return scoped
    }
}
