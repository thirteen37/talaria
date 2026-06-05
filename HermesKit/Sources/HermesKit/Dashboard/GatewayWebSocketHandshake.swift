import Crypto
import Foundation

/// Pure RFC 6455 client-handshake helpers for the iOS `/api/ws` tunnel. Kept
/// free of NIO types so the (security-relevant) key/accept logic and the
/// request/response wire format are unit-testable in isolation — the NIO
/// pipeline in ``NIOSSHGatewayWebSocket`` just drives these.
enum GatewayWebSocketHandshake {
    /// The fixed RFC 6455 GUID concatenated with the client key to derive the
    /// server's `Sec-WebSocket-Accept`.
    static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// A fresh 16-byte client key, base64-encoded (`Sec-WebSocket-Key`).
    static func makeKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        return Data(bytes).base64EncodedString()
    }

    /// The `Sec-WebSocket-Accept` the server must return for `key`:
    /// base64(SHA1(key + GUID)). Used to validate the 101 response.
    static func expectedAccept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + acceptGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    /// The HTTP/1.1 Upgrade request bytes. `path` is origin-form
    /// (`/api/ws?token=…`); `host` is `127.0.0.1:<port>`.
    static func requestBytes(path: String, host: String, key: String) -> Data {
        var text = "GET \(path) HTTP/1.1\r\n"
        text += "Host: \(host)\r\n"
        text += "Upgrade: websocket\r\n"
        text += "Connection: Upgrade\r\n"
        text += "Sec-WebSocket-Key: \(key)\r\n"
        text += "Sec-WebSocket-Version: 13\r\n"
        text += "\r\n"
        return Data(text.utf8)
    }

    struct Response: Equatable {
        let status: Int
        let accept: String?
        /// Byte offset just past the header terminator, so the caller can keep
        /// any WebSocket frame bytes the server pipelined after the 101.
        let headerByteCount: Int
    }

    /// Parses a (possibly partial) handshake response. Returns `nil` until the
    /// full header block (`\r\n\r\n`) has arrived, so the caller can keep
    /// buffering. On completion, exposes the status and `Sec-WebSocket-Accept`.
    static func parseResponse(_ data: Data) -> Response? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: terminator) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }

        var accept: String?
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            if name.lowercased() == "sec-websocket-accept" {
                accept = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return Response(status: status, accept: accept, headerByteCount: range.upperBound - data.startIndex)
    }

    /// True if `response` is a valid 101 upgrade for `key`.
    static func isValidUpgrade(_ response: Response, key: String) -> Bool {
        response.status == 101 && response.accept == expectedAccept(for: key)
    }
}
