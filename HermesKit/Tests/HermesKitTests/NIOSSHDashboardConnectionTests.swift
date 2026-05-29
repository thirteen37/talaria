import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import HermesKit

@Suite
struct NIOSSHDashboardConnectionTests {
    // MARK: - Request URI

    @Test
    func requestURIIncludesPathAndQuery() {
        let url = URL(string: "http://127.0.0.1:48213/api/sessions/search?q=hello%20world&limit=200")!
        #expect(DashboardHTTPWire.requestURI(from: url) == "/api/sessions/search?q=hello%20world&limit=200")
    }

    @Test
    func requestURIPathOnly() {
        let url = URL(string: "http://127.0.0.1:48213/api/status")!
        #expect(DashboardHTTPWire.requestURI(from: url) == "/api/status")
    }

    @Test
    func requestURIEmptyPathFallsBackToRoot() {
        let url = URL(string: "http://127.0.0.1:48213")!
        #expect(DashboardHTTPWire.requestURI(from: url) == "/")
    }

    // MARK: - Request serialization

    @Test
    func serializeRequestEmitsRequestLineHostAndHeaders() {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:51000/api/sessions/delete")!)
        request.httpMethod = "POST"
        request.setValue("tok-123", forHTTPHeaderField: "X-Hermes-Session-Token")
        request.httpBody = Data("{}".utf8)

        let wire = String(decoding: DashboardHTTPWire.serializeRequest(request, url: request.url!, targetPort: 51000), as: UTF8.self)

        #expect(wire.hasPrefix("POST /api/sessions/delete HTTP/1.1\r\n"))
        #expect(wire.contains("Host: 127.0.0.1:51000\r\n"))
        #expect(wire.contains("Connection: close\r\n"))
        #expect(wire.contains("Content-Length: 2\r\n"))
        #expect(wire.contains("X-Hermes-Session-Token: tok-123\r\n"))
        #expect(wire.hasSuffix("\r\n\r\n{}"))
    }

    @Test
    func serializeRequestDefaultsToGETWithNoContentLength() {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:51000/api/status")!)
        let wire = String(decoding: DashboardHTTPWire.serializeRequest(request, url: request.url!, targetPort: 51000), as: UTF8.self)
        #expect(wire.hasPrefix("GET /api/status HTTP/1.1\r\n"))
        #expect(!wire.contains("Content-Length"))
    }

    // MARK: - Response parsing

    @Test
    func parseResponseSplitsStatusHeadersAndBody() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 5\r\n\r\nhello".utf8)
        let parsed = try DashboardHTTPWire.parseResponse(raw)
        #expect(parsed.status == 200)
        #expect(parsed.headers["Content-Type"] == "application/json")
        #expect(String(decoding: parsed.body, as: UTF8.self) == "hello")
    }

    @Test
    func parseResponseHandlesEmptyBody() throws {
        let raw = Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)
        let parsed = try DashboardHTTPWire.parseResponse(raw)
        #expect(parsed.status == 204)
        #expect(parsed.body.isEmpty)
    }

    @Test
    func parseResponseRejectsMissingTerminator() {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n".utf8)
        #expect(throws: DashboardHTTPWire.WireError.self) {
            _ = try DashboardHTTPWire.parseResponse(raw)
        }
    }

    // MARK: - Spawn spec

    @Test
    func remoteNIOSpecBuildsWrappedDashboardCommand() {
        let profile = ServerProfile(
            name: "Remote",
            kind: .ssh,
            host: "example.com",
            hermesPath: "hermes",
            remoteShellMode: .bashLogin
        )
        let spec = DashboardSpawnSpec.remoteNIO(profile: profile, port: 49231)
        #expect(spec.arguments.count == 1)
        let command = spec.arguments[0]
        #expect(command.contains("dashboard"))
        #expect(command.contains("--port 49231"))
        #expect(command.contains("--host 127.0.0.1"))
    }

    // MARK: - direct-tcpip response collector

    /// The collector unwraps `SSHChannelData` byte payloads, accumulates them
    /// across reads, and resolves only when the channel closes (our
    /// `Connection: close` end-of-response signal).
    @Test
    func responseCollectorAccumulatesUntilChannelClose() throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        let promise = loop.makePromise(of: ByteBuffer.self)
        try channel.pipeline.syncOperations.addHandler(
            DirectTCPIPResponseCollector(promise: promise, allocator: channel.allocator)
        )

        func feed(_ text: String) throws {
            var buffer = channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
        }
        try feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n")
        try feed("\r\nhel")
        try feed("lo")

        // Not resolved until the channel closes (channelInactive).
        _ = try channel.finish()
        loop.run()
        let collected = try promise.futureResult.wait()
        let parsed = try DashboardHTTPWire.parseResponse(Data(collected.readableBytesView))
        #expect(parsed.status == 200)
        #expect(String(decoding: parsed.body, as: UTF8.self) == "hello")
    }
}
