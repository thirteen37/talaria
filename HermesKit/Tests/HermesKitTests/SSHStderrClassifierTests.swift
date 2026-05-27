import Testing
@testable import HermesKit

/// Mirror of the classifier suite from ``SSHTransportTests`` against the
/// extracted free function. Lives in its own file (no `#if os(macOS)`) so
/// the iOS Simulator build covers the classifier too — the NIO transport
/// uses it whenever the *remote* process emits a recognizable stderr line.
@Suite
struct SSHStderrClassifierTests {
    @Test
    func mapsPermissionDeniedToAuthFailure() {
        let result = SSHStderrClassifier.classify("me@host: Permission denied (publickey).")
        if case .authFailed = result { return }
        Issue.record("Expected .authFailed, got \(result)")
    }

    @Test
    func mapsBareNoSupportedAuthToAuthFailure() {
        let result = SSHStderrClassifier.classify("No supported authentication methods available")
        if case .authFailed = result { return }
        Issue.record("Expected .authFailed, got \(result)")
    }

    @Test
    func mapsHostKeyFailure() {
        let stderr = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Host key verification failed.
        """
        let result = SSHStderrClassifier.classify(stderr)
        if case .hostKeyVerification = result { return }
        Issue.record("Expected .hostKeyVerification, got \(result)")
    }

    @Test
    func mapsTimeout() {
        let result = SSHStderrClassifier.classify("ssh: connect to host example.com port 22: Connection timed out")
        if case .commandTimeout = result { return }
        Issue.record("Expected .commandTimeout, got \(result)")
    }

    @Test
    func mapsUnreachable() {
        let cases = [
            "ssh: Could not resolve hostname nope.invalid: nodename nor servname provided, or not known",
            "ssh: connect to host x port 22: Connection refused",
            "ssh: connect to host x port 22: No route to host",
        ]
        for stderr in cases {
            let result = SSHStderrClassifier.classify(stderr)
            if case .hostUnreachable = result { continue }
            Issue.record("Expected .hostUnreachable for \(stderr), got \(result)")
        }
    }

    @Test
    func fallsBackToOther() {
        let result = SSHStderrClassifier.classify("kex_exchange_identification: read: Connection reset by peer")
        if case .other = result { return }
        Issue.record("Expected .other, got \(result)")
    }

    @Test
    func emptyStderr() {
        let result = SSHStderrClassifier.classify("   \n\n")
        if case .other = result { return }
        Issue.record("Expected .other for empty stderr, got \(result)")
    }
}
