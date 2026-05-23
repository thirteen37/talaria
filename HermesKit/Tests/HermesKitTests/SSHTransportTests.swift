#if os(macOS)
import Testing
@testable import HermesKit

@Suite
struct SSHTransportTests {
    @Test
    func remoteCommandStartsAfterDestination() {
        let arguments = SSHTransport.makeArguments(
            host: "example.com",
            user: "me",
            port: 2222,
            identityFile: "~/.ssh/id_ed25519",
            hermesPath: "/opt/bin/hermes",
            hermesHome: "/tmp/hermes"
        )

        #expect(arguments == [
            "-T",
            "-o",
            "BatchMode=yes",
            "-p",
            "2222",
            "-i",
            "~/.ssh/id_ed25519",
            "--",
            "me@example.com",
            "env",
            "'HERMES_HOME=/tmp/hermes'",
            "'/opt/bin/hermes'",
            "acp",
        ])
    }

    @Test
    func remoteCommandInsertsAreShellQuoted() {
        let arguments = SSHTransport.makeArguments(
            host: "example.com",
            hermesPath: "/opt/Hermes Bin/hermes'agent",
            hermesHome: "/var/lib/hermes data/it's; rm -rf ~"
        )

        #expect(arguments.suffix(4).elementsEqual([
            "env",
            "'HERMES_HOME=/var/lib/hermes data/it'\\''s; rm -rf ~'",
            "'/opt/Hermes Bin/hermes'\\''agent'",
            "acp",
        ]))
    }

    @Test
    func destinationIsSeparatedFromSSHOptions() {
        let arguments = SSHTransport.makeArguments(
            host: "-oProxyCommand=touch /tmp/bad",
            user: "-lroot"
        )

        #expect(arguments.contains("--"))
        #expect(arguments.suffix(4).elementsEqual([
            "--",
            "-lroot@-oProxyCommand=touch /tmp/bad",
            "'hermes'",
            "acp",
        ]))
    }

    @Test
    func probeArgumentsIncludeBatchModeAndTimeout() {
        let arguments = SSHTransport.probeArguments(
            host: "example.com",
            user: "me",
            port: 2200,
            identityFile: "~/.ssh/id_ed25519",
            connectTimeout: 7
        )

        #expect(arguments == [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=7",
            "-p", "2200",
            "-i", "~/.ssh/id_ed25519",
            "--",
            "me@example.com",
            "printf", "ok",
        ])
    }

    @Test
    func classifierMapsPermissionDeniedToAuthFailure() {
        let result = SSHTransport.classifyStderr("me@host: Permission denied (publickey).")
        if case .authFailed = result {
            // ok
        } else {
            Issue.record("Expected .authFailed, got \(result)")
        }
    }

    @Test
    func classifierMapsBareNoSupportedAuthToAuthFailure() {
        let result = SSHTransport.classifyStderr("No supported authentication methods available")
        if case .authFailed = result {
            // ok
        } else {
            Issue.record("Expected .authFailed, got \(result)")
        }
    }

    @Test
    func classifierMapsHostKeyFailure() {
        let stderr = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Host key verification failed.
        """
        let result = SSHTransport.classifyStderr(stderr)
        if case .hostKeyVerification = result {
            // ok
        } else {
            Issue.record("Expected .hostKeyVerification, got \(result)")
        }
    }

    @Test
    func classifierMapsTimeout() {
        let result = SSHTransport.classifyStderr("ssh: connect to host example.com port 22: Connection timed out")
        if case .commandTimeout = result {
            // ok
        } else {
            Issue.record("Expected .commandTimeout, got \(result)")
        }
    }

    @Test
    func classifierMapsUnreachable() {
        let cases = [
            "ssh: Could not resolve hostname nope.invalid: nodename nor servname provided, or not known",
            "ssh: connect to host x port 22: Connection refused",
            "ssh: connect to host x port 22: No route to host",
        ]
        for stderr in cases {
            let result = SSHTransport.classifyStderr(stderr)
            if case .hostUnreachable = result {
                continue
            }
            Issue.record("Expected .hostUnreachable for \(stderr), got \(result)")
        }
    }

    @Test
    func classifierFallsBackToOther() {
        let result = SSHTransport.classifyStderr("kex_exchange_identification: read: Connection reset by peer")
        if case .other = result {
            // ok
        } else {
            Issue.record("Expected .other, got \(result)")
        }
    }

    @Test
    func classifierEmptyStderr() {
        let result = SSHTransport.classifyStderr("   \n\n")
        if case .other = result {
            // ok
        } else {
            Issue.record("Expected .other for empty stderr, got \(result)")
        }
    }
}
#endif
