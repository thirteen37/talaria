import Foundation
import NIOCore
import NIOSSH

/// Maps a NIO-SSH connect-time error into a typed ``SSHTransportError`` so the
/// host app can pattern-match it. Used by the NIO command runner and the
/// snapshot transfer; previously lived on the chat `NIOSSHTransport`.
public enum NIOSSHConnectError {
    public static func map(_ error: Error, host: String, port: Int) -> Error {
        // SSH-layer errors we raise from our own delegates pass through unchanged
        // so callers can pattern-match on them. Everything else maps to a generic
        // ``SSHTransportError``.
        if let typed = error as? SSHTransportError {
            return typed
        }
        if let typed = error as? HostKeyStoreError {
            return SSHTransportError.other(typed.errorDescription ?? "\(typed)")
        }
        if let nio = error as? NIOSSHError {
            return SSHTransportError.authFailed(String(describing: nio))
        }
        // `ChannelError`'s NSError bridge yields a useless "operation couldn't be
        // completed" string. A channel-layer failure during connect means the TCP
        // socket was refused, reset, or never established — on iOS the most common
        // cause is Local Network privacy not yet granted for a LAN host. Render
        // the case name and a hint instead of the opaque code.
        if let channelError = error as? ChannelError {
            return SSHTransportError.hostUnreachable(
                "\(host):\(port) — connection failed (\(String(describing: channelError))). "
                + "Check the host/port is reachable. On iOS, allow Local Network access for Talaria if the server is on your LAN."
            )
        }
        let message = (error as NSError).localizedDescription
        let lowered = message.lowercased()
        if lowered.contains("connection refused")
            || lowered.contains("no route")
            || lowered.contains("network is unreachable")
            || lowered.contains("could not resolve") {
            return SSHTransportError.hostUnreachable("\(host):\(port) — \(message)")
        }
        return SSHTransportError.other(message)
    }
}
