import Foundation
import HermesKit

// Wraps a HermesAdminRunning and injects the user's login-shell PATH at call
// time. Avoids snapshotting the PATH at view construction (which would block
// first paint) by awaiting the shared resolver — itself non-blocking once the
// initial probe has run.
struct PathAwareHermesAdminRunner: HermesAdminRunning {
    let inner: HermesAdminRunning
    let resolver: LoginShellPATHResolver

    func run(_ command: HermesAdminCommand) async throws -> HermesAdminResult {
        let extra = await resolver.extraEnv()
        var env = command.environment
        for (key, value) in extra where env[key] == nil {
            env[key] = value
        }
        return try await inner.run(HermesAdminCommand(arguments: command.arguments, environment: env))
    }
}
