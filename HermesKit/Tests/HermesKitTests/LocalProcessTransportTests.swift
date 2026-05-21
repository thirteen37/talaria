#if os(macOS)
import Foundation
import Testing
@testable import HermesKit

@Suite
struct LocalProcessTransportTests {
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
#endif
