import Foundation

public protocol Transport: Sendable {
    var inbound: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data) async throws
    func close() async
}

public enum TransportError: Error, Equatable, Sendable, LocalizedError {
    case processAlreadyStarted
    case processNotStarted
    case processDidNotStart(String)
    case stdinClosed
    case transportClosed
    case writeFailed(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .processAlreadyStarted:
            return "Transport process is already running."
        case .processNotStarted:
            return "Transport process hasn't started yet."
        case let .processDidNotStart(message):
            return "Couldn't launch transport process: \(message)"
        case .stdinClosed:
            return "Transport stdin is closed; can't send data."
        case .transportClosed:
            return "Transport is closed."
        case let .writeFailed(message):
            return "Failed to write to transport: \(message)"
        case .unsupportedPlatform:
            return "Local profiles aren't supported on this device. Configure a remote (SSH) profile in Settings to chat from here."
        }
    }
}
