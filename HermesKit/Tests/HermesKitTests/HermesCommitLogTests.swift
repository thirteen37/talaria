import Foundation
import NIOCore
import Testing
@testable import HermesKit

/// Stub host shell for the commit-log fetcher: records every script it's asked to
/// run and returns either a canned result or throws. Lets the fetcher be driven
/// without a real git checkout, and lets a test assert the `-n <cap>` clamp.
private final class StubHostShell: HostShellRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [String] = []
    private var _workingDirectories: [String?] = []
    private let result: Result<RemoteCommandResult, Error>

    init(_ result: Result<RemoteCommandResult, Error>) { self.result = result }

    convenience init(exitCode: Int, stdout: String, stderr: String = "") {
        self.init(.success(RemoteCommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)))
    }

    var scripts: [String] { lock.withLock { _scripts } }
    var workingDirectories: [String?] { lock.withLock { _workingDirectories } }

    func runShell(_ script: String, workingDirectory: String?) async throws -> RemoteCommandResult {
        lock.withLock {
            _scripts.append(script)
            _workingDirectories.append(workingDirectory)
        }
        return try result.get()
    }
}

private struct StubShellError: Error {}

@Suite
struct HermesCommitLogTests {
    @Test
    func splitsStdoutIntoOrderedSubjectsFilteringBlanks() async {
        let shell = StubHostShell(exitCode: 0, stdout: "Add gateway chat\n\nFix WS timeout\n   \nBump deps\n")
        let fetcher = HostShellCommitLogFetcher(shell: shell, repoPath: "/repo")

        let commits = await fetcher.pendingCommits(limit: 50)

        #expect(commits == [
            PendingCommit(subject: "Add gateway chat"),
            PendingCommit(subject: "Fix WS timeout"),
            PendingCommit(subject: "Bump deps"),
        ])
        // cd is embedded in the script (workingDirectory left nil) so the host
        // shell can't single-quote a leading ~ — see tildeRepoPathExpandsViaHome.
        #expect(shell.workingDirectories == [nil])
        #expect(shell.scripts.first?.contains("cd '/repo'") == true)
    }

    @Test
    func tildeRepoPathExpandsViaHome() async {
        // The ~/.hermes default would be `cd '~/.hermes/...'` if quoted whole —
        // a literal tilde the shell never expands, so cd fails and we get 0
        // commits. Expand a leading ~ through "$HOME" instead.
        let shell = StubHostShell(exitCode: 0, stdout: "x")
        let fetcher = HostShellCommitLogFetcher(shell: shell, repoPath: "~/.hermes/hermes-agent")

        _ = await fetcher.pendingCommits(limit: 10)
        let script = shell.scripts.first ?? ""
        #expect(script.contains("\"$HOME\""))
        #expect(script.contains("/.hermes/hermes-agent"))
        // No single-quoted literal tilde.
        #expect(!script.contains("'~/"))
    }

    @Test
    func nonZeroExitYieldsEmpty() async {
        let shell = StubHostShell(exitCode: 128, stdout: "", stderr: "not a git repository")
        let fetcher = HostShellCommitLogFetcher(shell: shell, repoPath: "/repo")

        let commits = await fetcher.pendingCommits(limit: 50)
        #expect(commits.isEmpty)
    }

    @Test
    func emptyStdoutYieldsEmpty() async {
        let shell = StubHostShell(exitCode: 0, stdout: "")
        let fetcher = HostShellCommitLogFetcher(shell: shell, repoPath: "/repo")

        let commits = await fetcher.pendingCommits(limit: 50)
        #expect(commits.isEmpty)
    }

    @Test
    func throwingShellYieldsEmpty() async {
        let shell = StubHostShell(.failure(StubShellError()))
        let fetcher = HostShellCommitLogFetcher(shell: shell, repoPath: "/repo")

        let commits = await fetcher.pendingCommits(limit: 50)
        #expect(commits.isEmpty)
    }

    @Test
    func clampsLimitToUpperBound() async {
        let shell = StubHostShell(exitCode: 0, stdout: "x")
        let fetcher = HostShellCommitLogFetcher(shell: shell, repoPath: "/repo")

        _ = await fetcher.pendingCommits(limit: 99999)
        #expect(shell.scripts.first?.contains("-n 5000") == true)
    }

    @Test
    func clampsLimitToLowerBound() async {
        let shell = StubHostShell(exitCode: 0, stdout: "x")
        let fetcher = HostShellCommitLogFetcher(shell: shell, repoPath: "/repo")

        _ = await fetcher.pendingCommits(limit: 0)
        #expect(shell.scripts.first?.contains("-n 1") == true)
    }

    @Test
    func fetchesOriginMainThenLogsAgainstFetchHead() async {
        // The local `origin/main` ref is often stale (hermes' own update check
        // doesn't refresh it), so the fetcher must fetch first, then diff against
        // the just-fetched FETCH_HEAD.
        let shell = StubHostShell(exitCode: 0, stdout: "x")
        let fetcher = HostShellCommitLogFetcher(shell: shell, repoPath: "/repo")

        _ = await fetcher.pendingCommits(limit: 10)
        let script = shell.scripts.first ?? ""
        #expect(script.contains("git fetch"))
        #expect(script.contains("origin main"))
        #expect(script.contains("HEAD..FETCH_HEAD"))
    }

    @Test
    func repoPathDefaultsToHermesHomeUnderDefault() {
        #expect(HermesCommitLog.repoPath(hermesHome: nil) == "~/.hermes/hermes-agent")
        #expect(HermesCommitLog.repoPath(hermesHome: "") == "~/.hermes/hermes-agent")
    }

    @Test
    func repoPathAppendsToProvidedHome() {
        #expect(HermesCommitLog.repoPath(hermesHome: "~/work/.hermes") == "~/work/.hermes/hermes-agent")
        #expect(HermesCommitLog.repoPath(hermesHome: "/srv/hermes") == "/srv/hermes/hermes-agent")
        // A trailing slash doesn't double up.
        #expect(HermesCommitLog.repoPath(hermesHome: "/srv/hermes/") == "/srv/hermes/hermes-agent")
    }
}
