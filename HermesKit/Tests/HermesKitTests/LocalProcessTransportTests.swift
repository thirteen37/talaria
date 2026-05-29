#if os(macOS)
import Foundation
import Testing
@testable import HermesKit

@Suite
struct LocalProcessTransportTests {
    @Test
    func sendBeforeStartThrows() async throws {
        let transport = LocalProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat"]
        )

        await #expect(throws: TransportError.processNotStarted) {
            try await transport.send(Data("hello\n".utf8))
        }
    }

    @Test
    func sendsToEchoingProcessAndCloses() async throws {
        let transport = LocalProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read line; printf \"echo:%s\\n\" \"$line\""]
        )

        try transport.start()
        try await transport.send(Data("hello\n".utf8))

        var received = Data()
        for try await chunk in transport.inbound {
            received.append(chunk)
        }

        #expect(String(decoding: received, as: UTF8.self) == "echo:hello\n")
        await transport.close()
    }

    // Regression test for a data-loss race: bytes pulled out of the stdout FD
    // by the readability handler could be dropped if the process-termination
    // finish path won the readQueue ordering and finished the stream first. The
    // race is timing- and load-sensitive, so we run many echoing transports
    // concurrently to force the contention that surfaces it.
    @Test
    func concurrentEchoTransportsNeverDropOutput() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 64 {
                group.addTask {
                    let transport = LocalProcessTransport(
                        executableURL: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "read line; printf \"echo:%s\\n\" \"$line\""]
                    )
                    try transport.start()
                    try await transport.send(Data("hello\(index)\n".utf8))

                    var received = Data()
                    for try await chunk in transport.inbound {
                        received.append(chunk)
                    }

                    #expect(String(decoding: received, as: UTF8.self) == "echo:hello\(index)\n")
                    await transport.close()
                }
            }
            try await group.waitForAll()
        }
    }

    @Test
    func stdoutEOFFinishesInboundEvenIfProcessStaysAlive() async throws {
        let transport = LocalProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 1>&-; sleep 5"]
        )

        try transport.start()

        let nextChunk = try await withTimeout {
            var iterator = transport.inbound.makeAsyncIterator()
            return try await iterator.next()
        }

        #expect(nextChunk == nil)
        await transport.close()
    }

    @Test
    func drainsOutputWrittenImmediatelyBeforeExit() async throws {
        let transport = LocalProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'final-frame\\n'; printf 'stderr-tail' >&2"]
        )

        try transport.start()

        var received = Data()
        for try await chunk in transport.inbound {
            received.append(chunk)
        }

        #expect(String(decoding: received, as: UTF8.self) == "final-frame\n")
        #expect(transport.recentStderr().contains("stderr-tail"))
    }
}

private enum TestTimeout: Error {
    case timedOut
}

private func withTimeout<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            throw TestTimeout.timedOut
        }

        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
#endif
