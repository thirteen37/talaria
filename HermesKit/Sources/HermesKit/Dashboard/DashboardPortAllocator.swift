#if os(macOS)
import Foundation
import Darwin

public enum DashboardPortAllocatorError: Error, Equatable, Sendable, LocalizedError {
    case socketFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .socketFailed(code):
            return "Couldn't allocate a free TCP port (errno \(code))."
        }
    }
}

/// Asks the kernel for an unused ephemeral TCP port on loopback. Used by
/// the supervisor to pick a port for `hermes dashboard --port <N>`.
///
/// There is an unavoidable race between releasing the socket and the
/// dashboard binding it — another process could grab the same port in
/// between. Acceptable in practice because (a) the window is microseconds,
/// (b) Talaria's launch-and-poll loop fails fast if `--port` reports
/// "address already in use", and (c) the alternative (pass an actual
/// preallocated fd to the child) requires teaching `hermes dashboard` to
/// accept one.
public enum DashboardPortAllocator {
    public static func allocate() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { throw DashboardPortAllocatorError.socketFailed(errno) }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult != 0 { throw DashboardPortAllocatorError.socketFailed(errno) }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &length)
            }
        }
        if getResult != 0 { throw DashboardPortAllocatorError.socketFailed(errno) }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}
#endif
