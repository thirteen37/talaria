import Foundation
import Testing
@testable import HermesKit

@Suite
struct JSONRPCFramerTests {
    @Test
    func splitFramesAreBufferedUntilNewline() throws {
        var framer = JSONRPCFramer()

        #expect(try framer.append(Data(#"{"jsonrpc":"2.0""#.utf8)).isEmpty)
        let frames = try framer.append(Data(#","method":"initialize"}"#.utf8 + [0x0A]))

        #expect(frames.count == 1)
        #expect(String(decoding: frames[0], as: UTF8.self) == #"{"jsonrpc":"2.0","method":"initialize"}"#)
    }

    @Test
    func joinedFramesAreSplit() throws {
        var framer = JSONRPCFramer()
        let frames = try framer.append(Data("one\ntwo\n".utf8))

        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["one", "two"])
    }

    @Test
    func finishReturnsTrailingPartialFrame() {
        var framer = JSONRPCFramer()
        _ = try? framer.append(Data("partial".utf8))

        #expect(framer.finish().map { String(decoding: $0, as: UTF8.self) } == "partial")
        #expect(framer.finish() == nil)
    }
}
