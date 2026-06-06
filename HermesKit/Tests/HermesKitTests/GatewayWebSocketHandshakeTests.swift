import Foundation
import Testing
@testable import HermesKit

/// Unit tests for the pure RFC 6455 client-handshake logic used by the iOS
/// `/api/ws` tunnel. The well-known key/accept vector is from RFC 6455 §1.3.
@Suite
struct GatewayWebSocketHandshakeTests {
    @Test
    func acceptMatchesRFC6455Vector() {
        // RFC 6455 §1.3: key "dGhlIHNhbXBsZSBub25jZQ==" → accept
        // "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".
        let accept = GatewayWebSocketHandshake.expectedAccept(for: "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test
    func makeKeyIsSixteenRandomBytesBase64() {
        let key = GatewayWebSocketHandshake.makeKey()
        let decoded = Data(base64Encoded: key)
        #expect(decoded?.count == 16)
        // Two successive keys should differ (random nonce).
        #expect(GatewayWebSocketHandshake.makeKey() != GatewayWebSocketHandshake.makeKey())
    }

    @Test
    func requestBytesAreWellFormedUpgrade() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let bytes = GatewayWebSocketHandshake.requestBytes(
            path: "/api/ws?token=abc",
            host: "127.0.0.1:9119",
            key: key
        )
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("GET /api/ws?token=abc HTTP/1.1\r\n"))
        #expect(text.contains("Host: 127.0.0.1:9119\r\n"))
        #expect(text.contains("Upgrade: websocket\r\n"))
        #expect(text.contains("Connection: Upgrade\r\n"))
        #expect(text.contains("Sec-WebSocket-Key: \(key)\r\n"))
        #expect(text.contains("Sec-WebSocket-Version: 13\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test
    func parseResponseReturnsNilUntilHeadersComplete() {
        let partial = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n".utf8)
        #expect(GatewayWebSocketHandshake.parseResponse(partial) == nil)
    }

    @Test
    func parseResponseExtractsStatusAcceptAndOffset() throws {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let accept = GatewayWebSocketHandshake.expectedAccept(for: key)
        let header = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        // Append a stray byte the server pipelined after the handshake.
        var data = Data(header.utf8)
        data.append(0x81)
        let response = try #require(GatewayWebSocketHandshake.parseResponse(data))
        #expect(response.status == 101)
        #expect(response.accept == accept)
        #expect(response.headerByteCount == header.utf8.count)
        #expect(GatewayWebSocketHandshake.isValidUpgrade(response, key: key))
    }

    @Test
    func isValidUpgradeRejectsWrongAccept() {
        let response = GatewayWebSocketHandshake.Response(status: 101, accept: "wrong", headerByteCount: 10)
        #expect(GatewayWebSocketHandshake.isValidUpgrade(response, key: "dGhlIHNhbXBsZSBub25jZQ==") == false)
    }

    @Test
    func isValidUpgradeRejectsNon101() {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let response = GatewayWebSocketHandshake.Response(
            status: 403,
            accept: GatewayWebSocketHandshake.expectedAccept(for: key),
            headerByteCount: 10
        )
        #expect(GatewayWebSocketHandshake.isValidUpgrade(response, key: key) == false)
    }
}
