#if os(macOS)
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

    func runStream(_ command: HermesAdminCommand) -> AsyncThrowingStream<AdminEvent, Error> {
        let inner = inner
        let resolver = resolver
        return AsyncThrowingStream { continuation in
            let task = Task {
                let extra = await resolver.extraEnv()
                var env = command.environment
                for (key, value) in extra where env[key] == nil {
                    env[key] = value
                }
                let stream = inner.runStream(HermesAdminCommand(arguments: command.arguments, environment: env))
                do {
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
