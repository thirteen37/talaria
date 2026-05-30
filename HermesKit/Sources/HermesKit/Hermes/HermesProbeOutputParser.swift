import Foundation

/// Cross-platform parsing + script construction for the Hermes probe, shared
/// by the macOS `HermesProbe` (system-ssh / local) and the `#if`-free
/// `NIOHermesProbe`. Keeping the parse + script logic here means neither path
/// duplicates it and no `#if` is introduced.
public enum HermesProbeOutputParser {
    /// Minimum Hermes version we consider ACP-capable. Sprint 6 finalizes the
    /// real pin; for now we just record what we observed.
    public static let minimumACPVersion = HermesVersion(major: 0, minor: 0, patch: 0)

    /// Parses the captured stdout produced by
    /// `command -v hermes; hermes --version` (or the SSH equivalent).
    public static func parse(stdout: String) throws -> HermesProbeResult {
        let lines = stdout
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw HermesProbeError.versionUnparseable(stdout)
        }
        let binaryPath = lines[0]
        let versionLine = lines[1]
        guard let version = HermesVersion(versionLine) else {
            throw HermesProbeError.versionUnparseable(versionLine)
        }
        return HermesProbeResult(
            binaryPath: binaryPath,
            version: version,
            versionRaw: versionLine,
            acpSupported: version >= minimumACPVersion
        )
    }

    /// Builds the probe script. `command -v` prints the resolved path; `<bin>
    /// --version` prints e.g. "hermes 0.4.2". Output lands on stdout in that
    /// order, separated by a newline. `set -e` keeps us from reporting a
    /// parseable version when the binary wasn't found.
    public static func makeProbeScript(hermesPath: String) -> String {
        let quoted = ShellQuoting.shellQuote(hermesPath)
        return "set -e; command -v \(quoted); \(quoted) --version"
    }
}
