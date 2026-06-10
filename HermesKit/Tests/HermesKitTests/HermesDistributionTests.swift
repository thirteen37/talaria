import Foundation
import NIOCore
import Testing
@testable import HermesKit

/// Records each shell invocation (script + workingDirectory) and returns queued
/// canned results, so ``DistributionPublisher`` can be driven without a host.
private final class RecordingHostShell: HostShellRunning, @unchecked Sendable {
    struct Call: Equatable {
        let script: String
        let workingDirectory: String?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _results: [RemoteCommandResult]

    init(results: [RemoteCommandResult]) {
        self._results = results
    }

    var calls: [Call] { lock.withLock { _calls } }

    func runShell(_ script: String, workingDirectory: String?) async throws -> RemoteCommandResult {
        lock.withLock {
            _calls.append(Call(script: script, workingDirectory: workingDirectory))
            return _results.isEmpty
                ? RemoteCommandResult(exitCode: 0, stdout: "", stderr: "")
                : _results.removeFirst()
        }
    }
}

@Suite
struct DistributionManifestTests {
    @Test
    func roundTripsFullManifest() throws {
        let manifest = DistributionManifest(
            name: "cool-dist",
            version: "1.2.0",
            description: "A cool distribution",
            author: "Jane Doe",
            license: "MIT",
            hermesRequires: ">=0.15.0",
            envRequires: [
                EnvRequirement(name: "OPENAI_API_KEY", description: "Your key", required: true),
                EnvRequirement(name: "OPTIONAL_VAR", description: nil, required: false, defaultValue: "fallback"),
            ],
            distributionOwned: ["config.yaml", "SOUL.md"]
        )
        let yaml = try manifest.encodeYAML()
        let parsed = try DistributionManifest(parsingYAML: yaml)
        #expect(parsed == manifest)
    }

    @Test
    func encodeOmitsUnsetFields() throws {
        let manifest = DistributionManifest(name: "bare")
        let yaml = try manifest.encodeYAML()
        #expect(yaml.contains("name: bare"))
        #expect(!yaml.contains("version"))
        #expect(!yaml.contains("env_requires"))
        #expect(!yaml.contains("distribution_owned"))
    }

    @Test
    func parsesBareStringEnvEntry() throws {
        let yaml = """
        name: x
        env_requires:
          - JUST_A_NAME
        """
        let manifest = try DistributionManifest(parsingYAML: yaml)
        #expect(manifest.envRequires.count == 1)
        #expect(manifest.envRequires.first?.name == "JUST_A_NAME")
        #expect(manifest.envRequires.first?.required == true)
    }

    @Test
    func envRequiredDefaultsTrueWhenOmitted() throws {
        let yaml = """
        name: x
        env_requires:
          - name: VAR
            description: something
        """
        let manifest = try DistributionManifest(parsingYAML: yaml)
        #expect(manifest.envRequires.first?.required == true)
    }

    @Test
    func parseRejectsNonMappingRoot() {
        #expect(throws: DistributionManifestError.self) {
            _ = try DistributionManifest(parsingYAML: "- just\n- a\n- list")
        }
    }

    @Test
    func parseTreatsBlankAsEmptyName() throws {
        let manifest = try DistributionManifest(parsingYAML: "# only a comment\n")
        #expect(manifest.name == "")
    }
}

@Suite
struct HostShellScriptTests {
    @Test
    func composePrefixesCdWhenDirectoryGiven() {
        #expect(HostShellScript.compose("git status", workingDirectory: "/a/b") == "cd '/a/b' && git status")
    }

    @Test
    func composeQuotesDirectoryWithSpaces() {
        #expect(HostShellScript.compose("ls", workingDirectory: "/a b") == "cd '/a b' && ls")
    }

    @Test
    func composeLeavesScriptUnchangedWithoutDirectory() {
        #expect(HostShellScript.compose("ls", workingDirectory: nil) == "ls")
        #expect(HostShellScript.compose("ls", workingDirectory: "") == "ls")
    }
}

@Suite
struct DistributionPublisherTests {
    @Test
    func freshRepoScriptInitsAndSetsUpstream() {
        let script = DistributionPublisher.script(
            isFreshRepo: true,
            remoteURL: "git@github.com:jane/x.git",
            version: "v1.0.0",
            message: "Initial publish"
        )
        #expect(script.contains("git init"))
        #expect(script.contains("git branch -M main"))
        #expect(script.contains("git remote add origin 'git@github.com:jane/x.git'"))
        #expect(script.contains("git tag 'v1.0.0'"))
        #expect(script.contains("git push -u origin main --tags"))
        #expect(script.contains("git commit -m 'Initial publish'"))
    }

    @Test
    func existingRepoScriptCommitsTagsAndRepointsRemote() {
        let script = DistributionPublisher.script(
            isFreshRepo: false,
            remoteURL: "https://example.com/x.git",
            version: "v2.0.0",
            message: "Update"
        )
        #expect(!script.contains("git init"))
        #expect(script.contains("git remote set-url origin 'https://example.com/x.git'"))
        #expect(script.contains("git remote add origin 'https://example.com/x.git'"))
        #expect(script.contains("git tag 'v2.0.0'"))
        #expect(script.contains("git push origin HEAD --tags"))
    }

    @Test
    func scriptStagesAllowlistNotEverything() {
        // Security: never `git add -A` in the profile home — that would stage
        // `.env`, MEMORY.md/USER.md, and the sessions DB and push secrets.
        for fresh in [true, false] {
            let script = DistributionPublisher.script(
                isFreshRepo: fresh,
                remoteURL: "u",
                version: "v",
                message: "m"
            )
            #expect(!script.contains("git add -A"))
            #expect(script.contains("'distribution.yaml'"))
            #expect(script.contains("'SOUL.md'"))
            #expect(script.contains("'config.yaml'"))
            #expect(script.contains("'skills'"))
            #expect(script.contains("git add -- \"$p\""))
        }
        // The *staging* step never names secrets/private files (they appear in
        // the script only as `.gitignore` exclusions — the opposite of staging).
        let staging = DistributionPublisher.stagingCommand(ownedPaths: [])
        #expect(!staging.contains(".env"))
        #expect(!staging.contains("memories"))
        #expect(!staging.contains("state.db"))
    }

    @Test
    func scriptEnsuresGitignoreMirrorsHermesExclusions() throws {
        let ignore = DistributionPublisher.ensureGitignoreCommand()
        // Every Hermes "not in a distribution (ever)" path is written.
        for path in [
            "auth.json", ".env", "memories/", "sessions/",
            "state.db", "state.db-shm", "state.db-wal",
            "logs/", "workspace/", "plans/", "home/", "*_cache/", "local/",
        ] {
            #expect(ignore.contains("'\(path)'"))
        }
        // Idempotent append (whole-line match), not a clobber/truncate.
        #expect(ignore.contains("touch .gitignore"))
        #expect(ignore.contains("grep -qxF"))
        #expect(ignore.contains(">> .gitignore"))  // appends, never truncates

        // The .gitignore is ensured before staging, and is itself committed.
        let script = DistributionPublisher.script(isFreshRepo: true, remoteURL: "u", version: "v", message: "m")
        #expect(DistributionPublisher.standardPaths.contains(".gitignore"))
        let ignoreIdx = try #require(script.range(of: "grep -qxF"))
        let stageIdx = try #require(script.range(of: "git add -- "))
        #expect(ignoreIdx.lowerBound < stageIdx.lowerBound)
    }

    @Test
    func scriptStagesDistributionOwnedPaths() {
        let script = DistributionPublisher.script(
            isFreshRepo: true,
            remoteURL: "u",
            version: "v",
            message: "m",
            ownedPaths: ["data/custom.txt", "extra dir"]
        )
        #expect(script.contains("'data/custom.txt'"))
        #expect(script.contains("'extra dir'"))
    }

    @Test
    func publishProbesThenRunsFreshScript() async throws {
        let shell = RecordingHostShell(results: [
            RemoteCommandResult(exitCode: 0, stdout: "no\n", stderr: ""),       // probe → no .git
            RemoteCommandResult(exitCode: 0, stdout: "pushed\n", stderr: ""),   // git script
        ])
        let out = try await DistributionPublisher.publish(
            shell: shell,
            directory: "/home/u/.hermes/profiles/x",
            remoteURL: "git@github.com:jane/x.git",
            version: "v1.0.0",
            message: "Init"
        )
        #expect(out == "pushed")
        #expect(shell.calls.count == 2)
        #expect(shell.calls[0].workingDirectory == "/home/u/.hermes/profiles/x")
        #expect(shell.calls[0].script.contains("test -d .git"))
        #expect(shell.calls[1].script.contains("git init"))
    }

    @Test
    func publishUsesExistingScriptWhenGitPresent() async throws {
        let shell = RecordingHostShell(results: [
            RemoteCommandResult(exitCode: 0, stdout: "yes\n", stderr: ""),
            RemoteCommandResult(exitCode: 0, stdout: "ok", stderr: ""),
        ])
        try await DistributionPublisher.publish(
            shell: shell,
            directory: "/d",
            remoteURL: "u",
            version: "v",
            message: "m"
        )
        #expect(!shell.calls[1].script.contains("git init"))
    }

    @Test
    func publishThrowsGitFailedOnNonZeroExit() async {
        let shell = RecordingHostShell(results: [
            RemoteCommandResult(exitCode: 0, stdout: "yes\n", stderr: ""),
            RemoteCommandResult(exitCode: 128, stdout: "", stderr: "fatal: Authentication failed"),
        ])
        await #expect(throws: DistributionPublishError.self) {
            try await DistributionPublisher.publish(
                shell: shell,
                directory: "/d",
                remoteURL: "u",
                version: "v",
                message: "m"
            )
        }
    }
}
