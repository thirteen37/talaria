import Foundation

/// `DashboardProcessLauncher` for iOS: execs the remote `hermes dashboard`
/// over a shared ``NIOSSHDashboardConnection``. The connection is shared with
/// ``NIOSSHDashboardHTTP`` so the same SSH session carries both the dashboard
/// process and its HTTP traffic.
public struct NIOSSHDashboardProcessLauncher: DashboardProcessLauncher {
    private let connection: NIOSSHDashboardConnection

    public init(connection: NIOSSHDashboardConnection) {
        self.connection = connection
    }

    public func launch(spec: DashboardSpawnSpec) async throws -> any DashboardProcess {
        // `remoteNIO` puts the fully shell-wrapped remote command in
        // `arguments[0]`; there's no `executable` to run locally.
        guard let command = spec.arguments.first, !command.isEmpty else {
            throw SSHTransportError.other("dashboard spawn spec has no remote command")
        }
        try await connection.startDashboard(command: command)
        return NIOSSHDashboardProcess(connection: connection)
    }
}

/// `DashboardProcess` backed by a ``NIOSSHDashboardConnection``'s exec channel.
final class NIOSSHDashboardProcess: DashboardProcess, @unchecked Sendable {
    private let connection: NIOSSHDashboardConnection

    init(connection: NIOSSHDashboardConnection) {
        self.connection = connection
    }

    var stderr: AsyncStream<String> { connection.stderr }

    func terminate() async {
        await connection.terminate()
    }

    func waitForExit() async -> Int32 {
        await connection.waitForExit()
    }

    func exitCodeIfAvailable() async -> Int32? {
        connection.exitCodeIfAvailable()
    }
}

/// `DashboardHTTP` for iOS: routes every dashboard request through a
/// `direct-tcpip` channel on the shared ``NIOSSHDashboardConnection``. The
/// target port is taken from the request URL (the supervisor builds requests
/// against `http://127.0.0.1:<remotePort>`).
public struct NIOSSHDashboardHTTP: DashboardHTTP {
    private let connection: NIOSSHDashboardConnection

    public init(connection: NIOSSHDashboardConnection) {
        self.connection = connection
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let port = request.url?.port ?? 80
        return try await connection.httpRequest(request, targetPort: port)
    }
}
