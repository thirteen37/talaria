import Darwin
import Foundation

/// A client-ready way to reach a **remote** profile's Hindsight daemon, which
/// binds the remote host's loopback and so isn't directly dialable from the app.
/// `baseURL` + `http` are handed straight to ``HindsightAPIClient``; `teardown`
/// releases whatever tunnel was opened.
public struct HindsightRemoteConnection: Sendable {
    public let baseURL: URL
    public let http: any DashboardHTTP
    public let teardown: @Sendable () async -> Void

    public init(baseURL: URL, http: any DashboardHTTP, teardown: @escaping @Sendable () async -> Void) {
        self.baseURL = baseURL
        self.http = http
        self.teardown = teardown
    }
}

/// Opens a transport to a remote Hindsight daemon on `127.0.0.1:<remotePort>` of
/// the SSH host. Platform-specific: macOS spawns an `ssh -L` forward and talks
/// over a local loopback port; iOS opens a `direct-tcpip` channel on the shared
/// NIO-SSH connection.
public protocol HindsightRemoteTransport: Sendable {
    func connect(remotePort: Int) async throws -> HindsightRemoteConnection
}

#if os(macOS)
/// macOS transport: a managed `ssh -L <ephemeral>:127.0.0.1:<remotePort> -N`
/// forward (same auth/host-key trust as the dashboard), with `HindsightAPIClient`
/// pointed at the local end via `URLSession`. macOS-only — it spawns the system
/// `ssh` binary (no `Process`/system-ssh on iOS, which uses ``NIOHindsightTransport``).
public struct SSHForwardHindsightTransport: HindsightRemoteTransport {
    private let profile: ServerProfile
    private let launcher: any DashboardProcessLauncher
    private let http: any DashboardHTTP
    private let allocatePort: @Sendable () throws -> Int
    private let maxReadinessAttempts: Int
    private let pollInterval: Duration

    public init(
        profile: ServerProfile,
        launcher: any DashboardProcessLauncher = SystemDashboardProcessLauncher(),
        http: any DashboardHTTP = URLSession.shared,
        allocatePort: @escaping @Sendable () throws -> Int = { try DashboardPortAllocator.allocate() },
        maxReadinessAttempts: Int = 60,
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.profile = profile
        self.launcher = launcher
        self.http = http
        self.allocatePort = allocatePort
        self.maxReadinessAttempts = maxReadinessAttempts
        self.pollInterval = pollInterval
    }

    public func connect(remotePort: Int) async throws -> HindsightRemoteConnection {
        let localPort = try allocatePort()
        let spec = DashboardSpawnSpec.forward(profile: profile, localPort: localPort, remotePort: remotePort)
        let process = try await launcher.launch(spec: spec)

        // Wait until `ssh` has bound the local forward port (accepts a TCP
        // connect). The remote daemon may still be down — that surfaces as a
        // connection error on the first real request and classifies as
        // `.daemonUnreachable`, which is the right guidance.
        for _ in 0..<max(1, maxReadinessAttempts) {
            if Self.localPortAccepts(localPort) {
                return HindsightRemoteConnection(
                    baseURL: URL(string: "http://127.0.0.1:\(localPort)")!,
                    http: http,
                    teardown: { await process.terminate() }
                )
            }
            try? await Task.sleep(for: pollInterval)
        }
        // Never bound — auth/host failure or the forward couldn't start.
        await process.terminate()
        throw URLError(.cannotConnectToHost)
    }

    /// True once something is listening on `127.0.0.1:<port>` (the `ssh -L`
    /// listener). A refused connect (nothing bound yet) returns immediately.
    static func localPortAccepts(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
#endif

/// iOS / NIO transport: reuses the window's live ``NIOSSHDashboardConnection`` to
/// run HTTP over a `direct-tcpip` channel straight to the remote daemon's
/// loopback port — no local forward process. The shared dashboard connection
/// owns its own lifetime, so teardown is a no-op (per-request channels
/// auto-close).
public struct NIOHindsightTransport: HindsightRemoteTransport {
    private let connection: NIOSSHDashboardConnection

    public init(connection: NIOSSHDashboardConnection) {
        self.connection = connection
    }

    public func connect(remotePort: Int) async throws -> HindsightRemoteConnection {
        // `NIOSSHDashboardHTTP` targets the port embedded in each request URL,
        // so building the client against `127.0.0.1:<remotePort>` routes the
        // direct-tcpip channel to the remote daemon.
        HindsightRemoteConnection(
            baseURL: URL(string: "http://127.0.0.1:\(remotePort)")!,
            http: NIOSSHDashboardHTTP(connection: connection),
            teardown: {}
        )
    }
}
