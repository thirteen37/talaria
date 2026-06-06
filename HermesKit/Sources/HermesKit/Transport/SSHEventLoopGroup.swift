import NIOCore
import NIOPosix

/// Process-wide `EventLoopGroup` shared by every pure-Swift NIO-SSH consumer —
/// the dashboard connection, the command/admin runners, and the snapshot
/// transfer. A single shared loop keeps SSH work off the app's other threads
/// without spinning up a group per connection.
public enum SSHEventLoopGroup {
    public static let shared: EventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}
