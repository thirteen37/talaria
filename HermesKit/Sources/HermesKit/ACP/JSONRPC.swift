import Foundation

public enum JSONRPCID: Hashable, Sendable {
    case string(String)
    case number(Int)
}

extension JSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer JSON-RPC id")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

public struct JSONRPCRequest<Params: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var method: String
    public var params: Params?

    public init(id: JSONRPCID, method: String, params: Params? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification<Params: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc: String
    public var method: String
    public var params: Params?

    public init(method: String, params: Params? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public struct JSONRPCResponse<Result: Codable & Sendable>: Codable, Sendable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var result: Result?
    public var error: JSONRPCError?

    public init(id: JSONRPCID, result: Result) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCID, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct JSONRPCInboundMessage: Codable, Sendable {
    public var jsonrpc: String?
    public var id: JSONRPCID?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var hasResult: Bool
    public var error: JSONRPCError?

    public init(
        jsonrpc: String? = nil,
        id: JSONRPCID? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        hasResult: Bool = false,
        error: JSONRPCError? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.hasResult = hasResult
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        hasResult = container.contains(.result)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        if hasResult {
            try container.encode(result ?? .null, forKey: .result)
        }
        try container.encodeIfPresent(error, forKey: .error)
    }
}

public struct JSONRPCError: Codable, Error, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
