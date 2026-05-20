#if os(macOS)
import Foundation

public final class SSHTransport: Transport, @unchecked Sendable {
    public var inbound: AsyncThrowingStream<Data, Error> {
        processTransport.inbound
    }

    private let processTransport: LocalProcessTransport

    public init(
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        hermesPath: String = "hermes",
        hermesHome: String? = nil
    ) {
        var arguments = ["-T", "-o", "BatchMode=yes"]
        if let port {
            arguments += ["-p", String(port)]
        }
        if let identityFile {
            arguments += ["-i", identityFile]
        }

        let destination = user.map { "\($0)@\(host)" } ?? host
        arguments += [destination, "--"]
        if let hermesHome {
            arguments += ["env", "HERMES_HOME=\(hermesHome)"]
        }
        arguments += [hermesPath, "acp"]

        self.processTransport = LocalProcessTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments
        )
    }

    public func start() throws {
        try processTransport.start()
    }

    public func send(_ data: Data) async throws {
        try await processTransport.send(data)
    }

    public func close() async {
        await processTransport.close()
    }

    public func recentStderr() -> String {
        processTransport.recentStderr()
    }
}
#endif
