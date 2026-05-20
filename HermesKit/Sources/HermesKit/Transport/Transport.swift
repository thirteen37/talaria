import Foundation

public protocol Transport: Sendable {
    var inbound: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data) async throws
    func close() async
}

public enum TransportError: Error, Equatable, Sendable {
    case processAlreadyStarted
    case processDidNotStart(String)
    case stdinClosed
    case unsupportedPlatform
}
