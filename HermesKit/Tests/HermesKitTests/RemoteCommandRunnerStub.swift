import Foundation
import NIOCore
@testable import HermesKit

/// Records the command/timeout it was asked to run and returns a canned
/// result (or throws a canned ``SSHTransportError``). Lets the NIO admin
/// runner and probe be tested for command construction + result mapping
/// without a live SSH connection.
final class StubRemoteCommandRunner: RemoteCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastCommand: String?
    private var _lastTimeout: TimeAmount?

    var lastCommand: String? { lock.withLock { _lastCommand } }
    var lastTimeout: TimeAmount? { lock.withLock { _lastTimeout } }

    private let result: RemoteCommandResult
    private let error: SSHTransportError?

    init(
        result: RemoteCommandResult = RemoteCommandResult(exitCode: 0, stdout: "", stderr: ""),
        error: SSHTransportError? = nil
    ) {
        self.result = result
        self.error = error
    }

    func run(command: String, timeout: TimeAmount) async throws -> RemoteCommandResult {
        lock.withLock {
            _lastCommand = command
            _lastTimeout = timeout
        }
        if let error { throw error }
        return result
    }
}
