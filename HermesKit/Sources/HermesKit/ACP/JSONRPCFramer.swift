import Foundation

public enum JSONRPCFramerError: Error, Equatable, Sendable {
    case lineTooLong(Int)
    case invalidUTF8
}

public struct JSONRPCFramer: Sendable {
    public var maximumFrameLength: Int
    private var buffer: Data

    public init(maximumFrameLength: Int = 4 * 1024 * 1024) {
        self.maximumFrameLength = maximumFrameLength
        self.buffer = Data()
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= maximumFrameLength else {
            throw JSONRPCFramerError.lineTooLong(buffer.count)
        }

        var frames: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[..<newlineIndex]
            frames.append(Data(frame))
            buffer.removeSubrange(...newlineIndex)
        }
        return frames
    }

    public mutating func finish() -> Data? {
        guard !buffer.isEmpty else {
            return nil
        }
        defer { buffer.removeAll(keepingCapacity: true) }
        return buffer
    }

    public static func encode<T: Encodable>(_ value: T, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
