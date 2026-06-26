import Foundation
import Testing
@testable import HermesKit

/// `.homeRelative` resolves a path under the login user's home on both kinds:
/// remote transports (SFTP / `cat`) don't expand `~`/`$HOME`, so the remote form
/// must be a bare relative path (resolved against the SSH session's home), while
/// local expands under `NSHomeDirectory()`.
@Suite
struct HermesFileStoreHomeRelativeTests {
    @Test
    func remoteHomeRelativeIsBareRelativePath() {
        let profile = ServerProfile(name: "p", kind: .ssh, host: "h", user: "u")
        let path = HermesFileStore.remotePath(
            profile: profile,
            location: .homeRelative(tail: ".hindsight/profiles/metadata.json")
        )
        // No leading `~` or `/` — SFTP/`cat` resolve this against the remote $HOME.
        #expect(path == ".hindsight/profiles/metadata.json")
    }

    @Test
    func localHomeRelativeExpandsUnderHome() {
        let profile = ServerProfile(name: "p", kind: .local)
        let url = HermesFileStore.localURL(
            profile: profile,
            location: .homeRelative(tail: ".hindsight/config.json")
        )
        let expected = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".hindsight/config.json")
        #expect(url.path == expected.path)
    }
}
