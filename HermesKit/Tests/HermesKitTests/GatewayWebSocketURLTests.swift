import Foundation
import Testing
@testable import HermesKit

/// `makeWebSocketURL` must map an `http(s)` dashboard base to the matching
/// `ws(s)` URL and append the right credential query param — `?token=` for a
/// loopback session token, `?ticket=` for a gated single-use ticket.
@Suite
struct GatewayWebSocketURLTests {
    @Test
    func httpBaseBecomesWSWithTokenQuery() throws {
        let url = try #require(URLSessionGatewayWebSocket.makeWebSocketURL(
            base: URL(string: "http://127.0.0.1:9119")!,
            credential: .token("abc-123")
        ))
        #expect(url.absoluteString == "ws://127.0.0.1:9119/api/ws?token=abc-123")
    }

    @Test
    func httpsBaseBecomesWSSWithTicketQuery() throws {
        let url = try #require(URLSessionGatewayWebSocket.makeWebSocketURL(
            base: URL(string: "https://host:443")!,
            credential: .ticket("single-use-xyz")
        ))
        #expect(url.scheme == "wss")
        #expect(url.path == "/api/ws")
        #expect(url.query == "ticket=single-use-xyz")
    }

    @Test
    func credentialQueryNameMatchesCase() {
        #expect(GatewayCredential.token("t").queryName == "token")
        #expect(GatewayCredential.ticket("t").queryName == "ticket")
    }
}
