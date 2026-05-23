#if os(macOS)
import Foundation
import Testing
@testable import HermesKit

@Suite
struct RemoteSnapshotTests {
    @Test
    func localPathLivesUnderCacheRoot() async throws {
        let root = tmpDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = ServerProfile(name: "Box", kind: .ssh, host: "h")
        let snapshot = RemoteSnapshot(profile: profile, cacheRoot: root)
        let path = snapshot.localPath()
        #expect(path.pathComponents.contains(profile.id.uuidString))
        #expect(path.lastPathComponent == "state.db")
        // Directory is created on demand.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test
    func currentStateMissingWhenNoCache() async throws {
        let root = tmpDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = RemoteSnapshot(
            profile: ServerProfile(name: "Box", kind: .ssh, host: "h"),
            cacheRoot: root
        )
        let state = await snapshot.currentState()
        #expect(state == .missing)
    }

    @Test
    func currentStateFreshAfterWriting() async throws {
        let root = tmpDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = RemoteSnapshot(
            profile: ServerProfile(name: "Box", kind: .ssh, host: "h"),
            cacheRoot: root
        )
        let path = snapshot.localPath()
        try Data("hi".utf8).write(to: path)
        let state = await snapshot.currentState()
        if case .fresh = state {
            // ok
        } else {
            Issue.record("Expected .fresh, got \(state)")
        }
    }

    @Test
    func invalidateBackdatesCachedFile() async throws {
        let root = tmpDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = RemoteSnapshot(
            profile: ServerProfile(name: "Box", kind: .ssh, host: "h"),
            cacheRoot: root
        )
        let path = snapshot.localPath()
        try Data("hi".utf8).write(to: path)

        await snapshot.invalidate()
        let state = await snapshot.currentState()
        if case .stale = state {
            // ok
        } else {
            Issue.record("Expected .stale, got \(state)")
        }
    }

    @Test
    func remoteStateDBPathUsesShellExpandableHomeByDefault() {
        // Single-quoted `~` doesn't expand on the remote shell; the path
        // construction in runBackup uses double quotes, so we encode the
        // default with `$HOME`. Same applies to user-supplied tilde paths.
        #expect(RemoteSnapshot.remoteStateDBPath(hermesHome: nil) == "$HOME/.hermes/state.db")
        #expect(RemoteSnapshot.remoteStateDBPath(hermesHome: "~/.hermes") == "$HOME/.hermes/state.db")
        #expect(RemoteSnapshot.remoteStateDBPath(hermesHome: "~") == "$HOME/state.db")
        #expect(RemoteSnapshot.remoteStateDBPath(hermesHome: "/var/lib/hermes/") == "/var/lib/hermes/state.db")
        #expect(RemoteSnapshot.remoteStateDBPath(hermesHome: "$HOME/.hermes") == "$HOME/.hermes/state.db")
    }

    @Test
    func backupCommandIsNotDoubleWrapped() {
        // Regression: wrapping the whole cmd in `shellQuote` made the remote
        // shell try to exec the entire line as a single binary. Per-token
        // quoting only: the cmd line must start with `sqlite3` (not a
        // single-quoted blob) so the remote shell parses it as a command.
        let cmd = RemoteSnapshot.backupCommand(
            remoteDB: "$HOME/.hermes/state.db",
            remoteTmp: "/tmp/talaria-snapshot-abc.db"
        )
        #expect(cmd.hasPrefix("sqlite3 "))
        #expect(cmd.contains("\"$HOME/.hermes/state.db\""))
        #expect(cmd.contains(".backup '/tmp/talaria-snapshot-abc.db'"))
        // No outer single-quote wrap.
        #expect(!cmd.hasPrefix("'"))
    }

    @Test
    func cleanupCommandIsRmDashF() {
        let cmd = RemoteSnapshot.cleanupCommand(remoteTmp: "/tmp/talaria-snapshot-xyz.db")
        #expect(cmd == "rm -f '/tmp/talaria-snapshot-xyz.db'")
    }

    @Test
    func sftpGetCommandQuotesBothPaths() {
        // Spaces in either path (e.g. "/Users/John Doe/Library/Caches/...")
        // must not split into separate sftp args.
        let cmd = RemoteSnapshot.sftpGetCommand(
            remoteTmp: "/tmp/talaria-snapshot-x.db",
            localPath: "/Users/John Doe/Library/Caches/Talaria/abc/state.db"
        )
        #expect(cmd == "get \"/tmp/talaria-snapshot-x.db\" \"/Users/John Doe/Library/Caches/Talaria/abc/state.db\"")
    }

    @Test
    func sftpGetCommandEscapesEmbeddedQuotesAndBackslashes() {
        let cmd = RemoteSnapshot.sftpGetCommand(
            remoteTmp: "/tmp/a\"b.db",
            localPath: "/Users/x\\y/Library/state.db"
        )
        #expect(cmd == "get \"/tmp/a\\\"b.db\" \"/Users/x\\\\y/Library/state.db\"")
    }

    @Test
    func doubleQuoteHelperPreservesDollarForExpansion() {
        let quoted = SSHTransport.shellDoubleQuoteAllowingExpansion("$HOME/.hermes/state.db")
        // Wrapped in double quotes; `$` is intentionally left bare so the
        // remote shell expands it.
        #expect(quoted == "\"$HOME/.hermes/state.db\"")
        // Embedded double quotes and backticks are escaped.
        let nasty = SSHTransport.shellDoubleQuoteAllowingExpansion("a\"b`c\\d")
        #expect(nasty == "\"a\\\"b\\`c\\\\d\"")
    }

    @Test
    func subscribeYieldsInitialState() async throws {
        let root = tmpDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = RemoteSnapshot(
            profile: ServerProfile(name: "Box", kind: .ssh, host: "h"),
            cacheRoot: root
        )
        let stream = await snapshot.subscribe()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == .missing)
    }

    private func tmpDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermesKit-RemoteSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
#endif
