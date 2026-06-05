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

    // MARK: - exec handler stdout/stderr capture

    /// The exec handler must forward **stdout** (`.channel`), not just stderr:
    /// Hermes prints its "Building web UI…" marker to stdout, and the supervisor
    /// scans the combined stream to extend the reachability window and show the
    /// banner on the iOS/NIO remote path. Dropping stdout (the prior behavior)
    /// left the slow-remote-build case broken here; this guards the merge.
    @Test
    func execHandlerForwardsStdoutSoBuildMarkerIsCaptured() async throws {
        var stderrCont: AsyncStream<String>.Continuation!
        let stderrStream = AsyncStream<String> { stderrCont = $0 }
        var exitCont: AsyncStream<Int32>.Continuation!
        let exitStream = AsyncStream<Int32> { exitCont = $0 }
        _ = exitStream  // retain so the continuation stays valid for the test

        let handler = DashboardExecHandler(
            command: "hermes dashboard",
            stderr: stderrCont,
            exit: exitCont,
            exitBox: DashboardExitCodeBox()
        )
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)

        func feed(_ text: String, _ type: SSHChannelData.DataType) throws {
            var buffer = channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            try channel.writeInbound(SSHChannelData(type: type, data: .byteBuffer(buffer)))
        }
        try feed("Building web UI...\n", .channel)   // stdout — was previously dropped
        try feed("a stderr line\n", .stdErr)
        _ = try channel.finish()                      // channelInactive → stderr.finish()

        var collected = ""
        for await line in stderrStream { collected += line }

        #expect(collected.contains("Building web UI"))
        #expect(collected.contains("a stderr line"))
        // The point of the merge: the supervisor's build matcher latches on the
        // stdout marker, so the iOS reachability window extends and the banner fires.
        #expect(DashboardSupervisor.indicatesWebUIBuild(collected))
    }

    /// When the request deadline fires the collector is marked timed-out and
    /// the channel is closed; `channelInactive` must then fail the promise
    /// (rather than succeed with a partial buffer) so the poll loop surfaces
    /// an error instead of hanging.
    @Test
    func responseCollectorFailsWhenTimedOut() throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        let promise = loop.makePromise(of: ByteBuffer.self)
        let collector = DirectTCPIPResponseCollector(promise: promise, allocator: channel.allocator)
        try channel.pipeline.syncOperations.addHandler(collector)

        collector.markTimedOut()
        _ = try channel.finish()
        loop.run()

        #expect(throws: SSHTransportError.self) {
            _ = try promise.futureResult.wait()
        }
    }
}
