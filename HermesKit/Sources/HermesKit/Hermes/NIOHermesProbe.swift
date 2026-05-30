import Foundation
import NIOCore

/// Cross-platform Hermes probe over NIO-SSH. The system-ssh ``HermesProbe``
/// stays macOS-only; this is a *separate* `#if`-free type (no new branch inside
/// `HermesProbe`) that drives the same `command -v hermes; hermes --version`
/// script through an injected ``RemoteCommandRunning`` and parses the output
/// with the shared ``HermesProbeOutputParser``. The app passes a
/// ``NIOSSHCommandRunner`` wired with the window's shared host-key store and
/// trust confirmer.
public struct NIOHermesProbe {
    private let runner: RemoteCommandRunning

    public init(runner: RemoteCommandRunning) {
        self.runner = runner
    }

    public func probe(profile: ServerProfile, timeout: TimeInterval = 10) async throws -> HermesProbeResult {
        guard profile.kind == .ssh, !(profile.host ?? "").isEmpty else {
            throw HermesProbeError.probeFailed("profile is not an SSH profile")
        }
        let script = HermesProbeOutputParser.makeProbeScript(hermesPath: profile.hermesPath)
        // Run through a login shell so PATH resolution matches what the user
        // sees in Terminal — the same `sh -lc` wrapper the macOS SSH path
        // appends after the destination, here sent as the exec command.
        let command = "sh -lc \(ShellQuoting.shellQuote(script))"

        let result: RemoteCommandResult
        do {
            result = try await runner.run(command: command, timeout: .seconds(Int64(timeout)))
        } catch let error as SSHTransportError {
            // NIO surfaces auth / host-key / connect / timeout failures as typed
            // throws (the exit-code path never sees them), so classify here.
            throw HermesProbeError.transportFailed(error)
        }

        if result.exitCode != 0, result.stdout.isEmpty {
            // Separate an SSH-level failure (auth, host key) from a missing
            // hermes binary so the UI can render the right message.
            let classified = SSHStderrClassifier.classify(result.stderr)
            if case .other = classified {
                let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw HermesProbeError.binaryNotFound(detail)
            }
            throw HermesProbeError.transportFailed(classified)
        }

        return try HermesProbeOutputParser.parse(stdout: result.stdout)
    }
}
