import Foundation
import Testing
@testable import HermesKit

/// Honest WebSocket close diagnostics: a successful `101 Switching Protocols`
/// upgrade must never be reported as a rejection, and a real close code (e.g.
/// `1001` "going away") must be preferred over the handshake status so logs and
/// stream errors name the true cause. See ``URLSessionGatewayWebSocket``.
@Suite
struct GatewayWebSocketCloseClassificationTests {
    @Test
    func successfulUpgradeStatusIsNotARejection() {
        // 101 (and any 2xx) is a successful upgrade — classify as the underlying
        // transport error, NOT a handshake rejection.
        #expect(URLSessionGatewayWebSocket.classifyReceiveFailure(handshakeStatus: 101, closeCode: nil) == .underlying)
        #expect(URLSessionGatewayWebSocket.classifyReceiveFailure(handshakeStatus: 200, closeCode: nil) == .underlying)
    }

    @Test
    func realRejectionStatusIsClassifiedAsRejection() {
        #expect(URLSessionGatewayWebSocket.classifyReceiveFailure(handshakeStatus: 403, closeCode: nil) == .handshakeRejected(403))
        #expect(URLSessionGatewayWebSocket.classifyReceiveFailure(handshakeStatus: 500, closeCode: nil) == .handshakeRejected(500))
    }

    @Test
    func closeCodeIsPreferredOverHandshakeStatus() {
        // A genuine mid-stream drop after a successful upgrade: the captured close
        // code (1001 going away) wins, so logs read code=1001 not HTTP 101.
        #expect(URLSessionGatewayWebSocket.classifyReceiveFailure(handshakeStatus: 101, closeCode: 1001) == .closeCode(1001))
        #expect(URLSessionGatewayWebSocket.classifyReceiveFailure(handshakeStatus: nil, closeCode: 1001) == .closeCode(1001))
    }

    @Test
    func noStatusOrCloseCodeFallsBackToUnderlying() {
        #expect(URLSessionGatewayWebSocket.classifyReceiveFailure(handshakeStatus: nil, closeCode: nil) == .underlying)
    }
}
