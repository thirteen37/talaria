import Foundation

public actor InMemoryTransport: Transport {
    public nonisolated let inbound: AsyncThrowingStream<Data, Error>

    private nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var outboundBuffer: [Data] = []
    private var closed = false

    public init() {
        var captured: AsyncThrowingStream<Data, Error>.Continuation?
        self.inbound = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.continuation = captured!
    }

    public func send(_ data: Data) async throws {
        guard !closed else {
            throw TransportError.stdinClosed
        }
        outboundBuffer.append(data)
    }

    public nonisolated func pushInbound(_ data: Data) {
        continuation.yield(data)
    }

    public nonisolated func finishInbound(throwing error: Error? = nil) {
        continuation.finish(throwing: error)
    }

    public func sentData() -> [Data] {
        return outboundBuffer
    }

    public func close() async {
        closed = true
        continuation.finish()
    }
}
