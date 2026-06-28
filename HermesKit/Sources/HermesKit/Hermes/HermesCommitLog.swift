import Foundation

/// One pending upstream commit on the Hermes source checkout — just its subject
/// line. The subject is all the changelog summarizer needs; full bodies would
/// blow the on-device model's small context window for little gain.
public struct PendingCommit: Sendable, Equatable {
    public let subject: String

    public init(subject: String) {
        self.subject = subject
    }
}

/// Fetches the commit subjects pending between a local Hermes **source** checkout
/// (`HEAD`) and `origin/main` — the commits a `hermes update` would pull in.
///
/// Contract: **never throws**. Any failure — not a git repo, no `origin/main`,
/// `git` missing, an SSH error, a timeout — returns `[]` so the changelog feature
/// degrades silently to the existing "N commits behind" subtitle. Only
/// source-install updates have a local commit source; semver/package installs
/// don't, and the caller skips them.
public protocol PendingCommitFetching: Sendable {
    /// Returns up to `limit` pending commit subjects in `git log` order (newest
    /// first). Returns `[]` on any failure.
    func pendingCommits(limit: Int) async -> [PendingCommit]
}

/// ``PendingCommitFetching`` over a ``HostShellRunning`` — runs `git` where the
/// Hermes repo actually lives (local disk on macOS, the remote host for an SSH
/// profile), the same proven host-shell path the distribution **Publish** flow
/// uses for remote git.
///
/// It **fetches first**. The local `origin/main` remote-tracking ref is usually
/// stale — `hermes update --check` computes "N commits behind" via its own
/// mechanism (`git ls-remote` / GitHub API) and does *not* refresh this repo's
/// refs — so diffing against the stale `origin/main` finds nothing. A fetch of
/// `origin main` writes `FETCH_HEAD`, and we diff `HEAD..FETCH_HEAD` against that
/// (robust regardless of the repo's remote-tracking refspec config). The fetch
/// only downloads objects/refs; it never touches the working tree.
public struct HostShellCommitLogFetcher: PendingCommitFetching {
    private let shell: any HostShellRunning
    private let repoPath: String

    public init(shell: any HostShellRunning, repoPath: String) {
        self.shell = shell
        self.repoPath = repoPath
    }

    public func pendingCommits(limit: Int) async -> [PendingCommit] {
        // Clamp the requested `limit`: 1 so the command is always valid, and a
        // generous hard ceiling so a caller can't trigger an unbounded `git log`.
        // The ceiling is deliberately far above any product cap (the changelog
        // summarizer passes its own `maxTotalCommits`, currently 500) so the
        // **caller's** limit is what actually binds — raising that constant up to
        // this ceiling works without the fetcher silently under-capping.
        let cap = min(max(limit, 1), 5000)
        // Build the `cd` ourselves and pass `workingDirectory: nil`. The host
        // shell applies a working directory by single-quoting it (`cd '<dir>'`),
        // which makes a leading `~` literal — `cd '~/.hermes/hermes-agent'` fails
        // with "No such file or directory", so the default home would always
        // yield 0 commits. ``shellCDTarget`` expands a leading `~` through
        // `"$HOME"` (works on both the local and remote shells) while keeping the
        // rest literal. Then: fetch `origin main` into FETCH_HEAD and list the
        // commits HEAD is behind it by. `&&` means a failed cd/fetch short-circuits
        // to a non-zero exit → `[]` → graceful fallback. `2>/dev/null` swallows
        // git's diagnostics — we detect failure by exit code, not noisy stderr.
        let script = "cd \(Self.shellCDTarget(repoPath)) && "
            + "git fetch --quiet origin main 2>/dev/null && "
            + "git log --no-merges --pretty=format:%s HEAD..FETCH_HEAD -n \(cap) 2>/dev/null"
        guard let result = try? await shell.runShell(script, workingDirectory: nil),
              result.exitCode == 0 else {
            return []
        }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { PendingCommit(subject: $0) }
    }

    /// Renders `path` as a shell `cd` target. A leading `~` (bare or `~/…`) is
    /// emitted as `"$HOME"` so the shell expands it; the remainder, and any
    /// non-tilde path, is single-quoted so spaces and globs stay literal. This is
    /// why the fetcher builds its own `cd` instead of relying on the host shell's
    /// working-directory handling, which would quote the tilde whole.
    static func shellCDTarget(_ path: String) -> String {
        if path == "~" {
            return "\"$HOME\""
        }
        if path.hasPrefix("~/") {
            // Keep the leading "/", drop only the "~", quote the literal rest.
            return "\"$HOME\"" + ShellQuoting.shellQuote(String(path.dropFirst()))
        }
        return ShellQuoting.shellQuote(path)
    }
}

/// Resolves where a profile's Hermes **source** repo lives.
public enum HermesCommitLog {
    /// `<hermesHome>/hermes-agent`, defaulting to `~/.hermes/hermes-agent` when
    /// `hermesHome` is nil/empty. A leading `~` is left intact — both the local
    /// and remote host shells exec via `/bin/sh`, which expands it.
    public static func repoPath(hermesHome: String?) -> String {
        let home = (hermesHome?.isEmpty == false) ? hermesHome! : "~/.hermes"
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return "\(base)/hermes-agent"
    }
}
