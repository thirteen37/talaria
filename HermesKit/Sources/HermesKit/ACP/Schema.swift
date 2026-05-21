import Foundation

public struct ACPClientInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String = "Talaria", version: String) {
        self.name = name
        self.version = version
    }
}

public struct ACPInitializeParams: Codable, Equatable, Sendable {
    public var clientInfo: ACPClientInfo
    public var protocolVersion: String
    public var capabilities: [String: JSONValue]

    public init(
        clientInfo: ACPClientInfo,
        protocolVersion: String,
        capabilities: [String: JSONValue] = [:]
    ) {
        self.clientInfo = clientInfo
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

public struct ACPInitializeResult: Codable, Equatable, Sendable {
    public var agentInfo: ACPAgentInfo
    public var protocolVersion: String
    public var capabilities: [String: JSONValue]

    public init(
        agentInfo: ACPAgentInfo,
        protocolVersion: String,
        capabilities: [String: JSONValue] = [:]
    ) {
        self.agentInfo = agentInfo
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

public struct ACPAgentInfo: Codable, Equatable, Sendable {
    public var name: String
    public var version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

public enum ACPMethod {
    public static let initialize = "initialize"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
}
