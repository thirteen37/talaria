import Foundation

public typealias ProtocolVersion = Int
public typealias SessionId = String
public typealias ToolCallId = String
public typealias RequestId = String
public typealias PermissionOptionId = String
public typealias PermissionOutcome = RequestPermissionOutcome
public typealias SessionModeId = String
public typealias SessionConfigId = String
public typealias SessionConfigGroupId = String
public typealias SessionConfigValueId = String

public enum ACPMethod {
    public static let initialize = "initialize"
    public static let authenticate = "authenticate"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"
    public static let sessionResume = "session/resume"
    public static let sessionList = "session/list"
    public static let sessionClose = "session/close"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    public static let sessionUpdate = "session/update"
    public static let sessionSetMode = "session/set_mode"
    public static let sessionSetConfigOption = "session/set_config_option"
    public static let sessionRequestPermission = "session/request_permission"
    public static let fsReadTextFile = "fs/read_text_file"
    public static let fsWriteTextFile = "fs/write_text_file"
    public static let terminalCreate = "terminal/create"
    public static let terminalOutput = "terminal/output"
    public static let terminalWaitForExit = "terminal/wait_for_exit"
    public static let terminalKill = "terminal/kill"
    public static let terminalRelease = "terminal/release"
}

public protocol ACPMessage: Codable, Equatable, Sendable {
    var meta: [String: JSONValue]? { get set }
}

public struct Implementation: ACPMessage {
    public var meta: [String: JSONValue]?
    public var name: String
    public var title: String?
    public var version: String

    public init(meta: [String: JSONValue]? = nil, name: String, title: String? = nil, version: String) {
        self.meta = meta
        self.name = name
        self.title = title
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case name
        case title
        case version
    }
}

public typealias ACPClientInfo = Implementation
public typealias ACPAgentInfo = Implementation

public struct InitializeRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var protocolVersion: ProtocolVersion
    public var clientCapabilities: ClientCapabilities?
    public var clientInfo: Implementation?

    public init(
        meta: [String: JSONValue]? = nil,
        protocolVersion: ProtocolVersion = 1,
        clientCapabilities: ClientCapabilities? = ClientCapabilities(),
        clientInfo: Implementation? = nil
    ) {
        self.meta = meta
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case protocolVersion
        case clientCapabilities
        case clientInfo
    }
}

public typealias ACPInitializeParams = InitializeRequest

public struct InitializeResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var protocolVersion: ProtocolVersion
    public var agentCapabilities: AgentCapabilities?
    public var agentInfo: Implementation?
    public var authMethods: [AuthMethod]?

    public init(
        meta: [String: JSONValue]? = nil,
        protocolVersion: ProtocolVersion,
        agentCapabilities: AgentCapabilities? = nil,
        agentInfo: Implementation? = nil,
        authMethods: [AuthMethod]? = []
    ) {
        self.meta = meta
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.agentInfo = agentInfo
        self.authMethods = authMethods
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case protocolVersion
        case agentCapabilities
        case agentInfo
        case authMethods
    }
}

public typealias ACPInitializeResult = InitializeResponse

public struct ClientCapabilities: ACPMessage {
    public var meta: [String: JSONValue]?
    public var fs: FileSystemCapabilities?
    public var terminal: Bool?

    public init(
        meta: [String: JSONValue]? = nil,
        fs: FileSystemCapabilities? = FileSystemCapabilities(),
        terminal: Bool? = false
    ) {
        self.meta = meta
        self.fs = fs
        self.terminal = terminal
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case fs
        case terminal
    }
}

public struct FileSystemCapabilities: ACPMessage {
    public var meta: [String: JSONValue]?
    public var readTextFile: Bool?
    public var writeTextFile: Bool?

    public init(meta: [String: JSONValue]? = nil, readTextFile: Bool? = false, writeTextFile: Bool? = false) {
        self.meta = meta
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case readTextFile
        case writeTextFile
    }
}

public struct AgentCapabilities: ACPMessage {
    public var meta: [String: JSONValue]?
    public var loadSession: Bool?
    public var mcpCapabilities: McpCapabilities?
    public var promptCapabilities: PromptCapabilities?
    public var sessionCapabilities: SessionCapabilities?

    public init(
        meta: [String: JSONValue]? = nil,
        loadSession: Bool? = false,
        mcpCapabilities: McpCapabilities? = McpCapabilities(),
        promptCapabilities: PromptCapabilities? = PromptCapabilities(),
        sessionCapabilities: SessionCapabilities? = SessionCapabilities()
    ) {
        self.meta = meta
        self.loadSession = loadSession
        self.mcpCapabilities = mcpCapabilities
        self.promptCapabilities = promptCapabilities
        self.sessionCapabilities = sessionCapabilities
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case loadSession
        case mcpCapabilities
        case promptCapabilities
        case sessionCapabilities
    }
}

public struct McpCapabilities: ACPMessage {
    public var meta: [String: JSONValue]?
    public var http: Bool?
    public var sse: Bool?

    public init(meta: [String: JSONValue]? = nil, http: Bool? = false, sse: Bool? = false) {
        self.meta = meta
        self.http = http
        self.sse = sse
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case http
        case sse
    }
}

public struct PromptCapabilities: ACPMessage {
    public var meta: [String: JSONValue]?
    public var audio: Bool?
    public var embeddedContext: Bool?
    public var image: Bool?

    public init(meta: [String: JSONValue]? = nil, audio: Bool? = false, embeddedContext: Bool? = false, image: Bool? = false) {
        self.meta = meta
        self.audio = audio
        self.embeddedContext = embeddedContext
        self.image = image
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case audio
        case embeddedContext
        case image
    }
}

public struct SessionCapabilities: ACPMessage {
    public var meta: [String: JSONValue]?
    public var load: Bool?
    public var list: SessionListCapabilities?
    public var close: SessionCloseCapabilities?
    public var resume: SessionResumeCapabilities?

    public init(
        meta: [String: JSONValue]? = nil,
        load: Bool? = nil,
        list: SessionListCapabilities? = nil,
        close: SessionCloseCapabilities? = nil,
        resume: SessionResumeCapabilities? = nil
    ) {
        self.meta = meta
        self.load = load
        self.list = list
        self.close = close
        self.resume = resume
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case load
        case list
        case close
        case resume
    }
}

public struct SessionListCapabilities: ACPMessage {
    public var meta: [String: JSONValue]?
    public init(meta: [String: JSONValue]? = nil) { self.meta = meta }
    enum CodingKeys: String, CodingKey { case meta = "_meta" }
}

public struct SessionCloseCapabilities: ACPMessage {
    public var meta: [String: JSONValue]?
    public init(meta: [String: JSONValue]? = nil) { self.meta = meta }
    enum CodingKeys: String, CodingKey { case meta = "_meta" }
}

public struct SessionResumeCapabilities: ACPMessage {
    public var meta: [String: JSONValue]?
    public init(meta: [String: JSONValue]? = nil) { self.meta = meta }
    enum CodingKeys: String, CodingKey { case meta = "_meta" }
}

public enum AuthMethod: Codable, Equatable, Sendable {
    case agent(AuthMethodAgent)
    case raw(JSONValue)

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        if case let .object(object) = value, object["type"] == .string("agent") {
            self = .agent(try JSONDecoder().decode(AuthMethodAgent.self, from: JSONEncoder().encode(value)))
        } else {
            self = .raw(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .agent(method):
            try method.encode(to: encoder)
        case let .raw(value):
            try value.encode(to: encoder)
        }
    }
}

public struct AuthMethodAgent: ACPMessage {
    public var meta: [String: JSONValue]?
    public var id: String
    public var name: String
    public var description: String?

    public init(meta: [String: JSONValue]? = nil, id: String, name: String, description: String? = nil) {
        self.meta = meta
        self.id = id
        self.name = name
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case id
        case name
        case description
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent([String: JSONValue].self, forKey: .meta)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
        try container.encode("agent", forKey: .type)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
    }
}

public struct AuthenticateRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var methodId: String
    public init(meta: [String: JSONValue]? = nil, methodId: String) {
        self.meta = meta
        self.methodId = methodId
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case methodId }
}

public struct AuthenticateResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public init(meta: [String: JSONValue]? = nil) { self.meta = meta }
    enum CodingKeys: String, CodingKey { case meta = "_meta" }
}

public struct NewSessionRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var cwd: String
    public var mcpServers: [McpServer]

    public init(meta: [String: JSONValue]? = nil, cwd: String, mcpServers: [McpServer] = []) {
        self.meta = meta
        self.cwd = cwd
        self.mcpServers = mcpServers
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case cwd
        case mcpServers
    }
}

public struct NewSessionResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]?

    public init(
        meta: [String: JSONValue]? = nil,
        sessionId: SessionId,
        modes: SessionModeState? = nil,
        configOptions: [SessionConfigOption]? = nil
    ) {
        self.meta = meta
        self.sessionId = sessionId
        self.modes = modes
        self.configOptions = configOptions
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionId
        case modes
        case configOptions
    }
}

public struct PromptRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId
    public var prompt: [ContentBlock]

    public init(meta: [String: JSONValue]? = nil, sessionId: SessionId, prompt: [ContentBlock]) {
        self.meta = meta
        self.sessionId = sessionId
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionId
        case prompt
    }
}

public struct PromptResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var stopReason: StopReason

    public init(meta: [String: JSONValue]? = nil, stopReason: StopReason) {
        self.meta = meta
        self.stopReason = stopReason
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case stopReason
    }
}

public struct CancelNotification: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId

    public init(meta: [String: JSONValue]? = nil, sessionId: SessionId) {
        self.meta = meta
        self.sessionId = sessionId
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionId
    }
}

public struct LoadSessionRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId
    public var cwd: String
    public var mcpServers: [McpServer]
    public init(meta: [String: JSONValue]? = nil, sessionId: SessionId, cwd: String, mcpServers: [McpServer] = []) {
        self.meta = meta
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case sessionId; case cwd; case mcpServers }
}

public struct LoadSessionResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]?
    public init(meta: [String: JSONValue]? = nil, modes: SessionModeState? = nil, configOptions: [SessionConfigOption]? = nil) {
        self.meta = meta
        self.modes = modes
        self.configOptions = configOptions
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case modes; case configOptions }
}

public typealias ResumeSessionRequest = LoadSessionRequest
public typealias ResumeSessionResponse = LoadSessionResponse

public struct ListSessionsRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var cwd: String?
    public var cursor: String?
    public init(meta: [String: JSONValue]? = nil, cwd: String? = nil, cursor: String? = nil) {
        self.meta = meta
        self.cwd = cwd
        self.cursor = cursor
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case cwd; case cursor }
}

public struct ListSessionsResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessions: [SessionInfo]
    public var nextCursor: String?
    public init(meta: [String: JSONValue]? = nil, sessions: [SessionInfo], nextCursor: String? = nil) {
        self.meta = meta
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case sessions; case nextCursor }
}

public struct CloseSessionRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId
    public init(meta: [String: JSONValue]? = nil, sessionId: SessionId) {
        self.meta = meta
        self.sessionId = sessionId
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case sessionId }
}

public struct CloseSessionResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public init(meta: [String: JSONValue]? = nil) { self.meta = meta }
    enum CodingKeys: String, CodingKey { case meta = "_meta" }
}

public enum McpServer: Codable, Equatable, Sendable {
    case stdio(McpServerStdio)
    case sse(McpServerSse)
    case http(McpServerHttp)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeCodingKeys.self)
        if let type = try container.decodeIfPresent(String.self, forKey: .type) {
            switch type {
            case "http":
                self = .http(try McpServerHttp(from: decoder))
            case "sse":
                self = .sse(try McpServerSse(from: decoder))
            default:
                self = .stdio(try McpServerStdio(from: decoder))
            }
        } else {
            self = .stdio(try McpServerStdio(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .stdio(server):
            try server.encode(to: encoder)
        case let .sse(server):
            try server.encode(to: encoder)
        case let .http(server):
            try server.encode(to: encoder)
        }
    }
}

public struct McpServerStdio: ACPMessage {
    public var meta: [String: JSONValue]?
    public var name: String
    public var command: String
    public var args: [String]
    public var env: [EnvVariable]

    public init(meta: [String: JSONValue]? = nil, name: String, command: String, args: [String] = [], env: [EnvVariable] = []) {
        self.meta = meta
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case name
        case command
        case args
        case env
    }
}

public struct McpServerSse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var name: String
    public var url: String
    public var headers: [HttpHeader]
    public init(meta: [String: JSONValue]? = nil, name: String, url: String, headers: [HttpHeader] = []) {
        self.meta = meta
        self.name = name
        self.url = url
        self.headers = headers
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case type; case name; case url; case headers }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent([String: JSONValue].self, forKey: .meta)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        headers = try container.decodeIfPresent([HttpHeader].self, forKey: .headers) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
        try container.encode("sse", forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(headers, forKey: .headers)
    }
}

public struct McpServerHttp: ACPMessage {
    public var meta: [String: JSONValue]?
    public var name: String
    public var url: String
    public var headers: [HttpHeader]
    public init(meta: [String: JSONValue]? = nil, name: String, url: String, headers: [HttpHeader] = []) {
        self.meta = meta
        self.name = name
        self.url = url
        self.headers = headers
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case type; case name; case url; case headers }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decodeIfPresent([String: JSONValue].self, forKey: .meta)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        headers = try container.decodeIfPresent([HttpHeader].self, forKey: .headers) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(meta, forKey: .meta)
        try container.encode("http", forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(headers, forKey: .headers)
    }
}

public struct EnvVariable: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct HttpHeader: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum ContentBlock: Codable, Equatable, Sendable {
    case text(TextContent)
    case image(ImageContent)
    case audio(AudioContent)
    case resourceLink(ResourceLink)
    case resource(EmbeddedResource)
    case unknown(JSONValue)

    public static func text(_ text: String) -> ContentBlock {
        .text(TextContent(text: text))
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(object) = value, case let .string(type)? = object["type"] else {
            self = .unknown(value)
            return
        }
        let data = try JSONEncoder().encode(value)
        let nestedDecoder = JSONDecoder()
        switch type {
        case "text":
            self = .text(try nestedDecoder.decode(TextContent.self, from: data))
        case "image":
            self = .image(try nestedDecoder.decode(ImageContent.self, from: data))
        case "audio":
            self = .audio(try nestedDecoder.decode(AudioContent.self, from: data))
        case "resource_link":
            self = .resourceLink(try nestedDecoder.decode(ResourceLink.self, from: data))
        case "resource":
            self = .resource(try nestedDecoder.decode(EmbeddedResource.self, from: data))
        default:
            self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(content):
            try content.encodeWithType("text", to: encoder)
        case let .image(content):
            try content.encodeWithType("image", to: encoder)
        case let .audio(content):
            try content.encodeWithType("audio", to: encoder)
        case let .resourceLink(content):
            try content.encodeWithType("resource_link", to: encoder)
        case let .resource(content):
            try content.encodeWithType("resource", to: encoder)
        case let .unknown(value):
            try value.encode(to: encoder)
        }
    }

    public var plainText: String? {
        if case let .text(content) = self {
            return content.text
        }
        return nil
    }
}

public struct Annotations: ACPMessage {
    public var meta: [String: JSONValue]?
    public var audience: [Role]?
    public var priority: Double?
    public init(meta: [String: JSONValue]? = nil, audience: [Role]? = nil, priority: Double? = nil) {
        self.meta = meta
        self.audience = audience
        self.priority = priority
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case audience; case priority }
}

public enum Role: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public struct TextContent: ACPMessage {
    public var meta: [String: JSONValue]?
    public var annotations: Annotations?
    public var text: String
    public init(meta: [String: JSONValue]? = nil, annotations: Annotations? = nil, text: String) {
        self.meta = meta
        self.annotations = annotations
        self.text = text
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case annotations; case text }
    fileprivate func encodeWithType(_ type: String, to encoder: Encoder) throws {
        try encodeAdding("type", value: type, to: encoder)
    }
}

public struct ImageContent: ACPMessage {
    public var meta: [String: JSONValue]?
    public var annotations: Annotations?
    public var data: String
    public var mimeType: String
    public var uri: String?
    public init(meta: [String: JSONValue]? = nil, annotations: Annotations? = nil, data: String, mimeType: String, uri: String? = nil) {
        self.meta = meta
        self.annotations = annotations
        self.data = data
        self.mimeType = mimeType
        self.uri = uri
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case annotations; case data; case mimeType; case uri }
    fileprivate func encodeWithType(_ type: String, to encoder: Encoder) throws {
        try encodeAdding("type", value: type, to: encoder)
    }
}

public struct AudioContent: ACPMessage {
    public var meta: [String: JSONValue]?
    public var annotations: Annotations?
    public var data: String
    public var mimeType: String
    public init(meta: [String: JSONValue]? = nil, annotations: Annotations? = nil, data: String, mimeType: String) {
        self.meta = meta
        self.annotations = annotations
        self.data = data
        self.mimeType = mimeType
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case annotations; case data; case mimeType }
    fileprivate func encodeWithType(_ type: String, to encoder: Encoder) throws {
        try encodeAdding("type", value: type, to: encoder)
    }
}

public struct ResourceLink: ACPMessage {
    public var meta: [String: JSONValue]?
    public var annotations: Annotations?
    public var name: String
    public var title: String?
    public var uri: String
    public var description: String?
    public var mimeType: String?
    public var size: Int?
    public init(meta: [String: JSONValue]? = nil, annotations: Annotations? = nil, name: String, title: String? = nil, uri: String, description: String? = nil, mimeType: String? = nil, size: Int? = nil) {
        self.meta = meta
        self.annotations = annotations
        self.name = name
        self.title = title
        self.uri = uri
        self.description = description
        self.mimeType = mimeType
        self.size = size
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case annotations; case name; case title; case uri; case description; case mimeType; case size }
    fileprivate func encodeWithType(_ type: String, to encoder: Encoder) throws {
        try encodeAdding("type", value: type, to: encoder)
    }
}

public struct EmbeddedResource: ACPMessage {
    public var meta: [String: JSONValue]?
    public var annotations: Annotations?
    public var resource: EmbeddedResourceResource
    public init(meta: [String: JSONValue]? = nil, annotations: Annotations? = nil, resource: EmbeddedResourceResource) {
        self.meta = meta
        self.annotations = annotations
        self.resource = resource
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case annotations; case resource }
    fileprivate func encodeWithType(_ type: String, to encoder: Encoder) throws {
        try encodeAdding("type", value: type, to: encoder)
    }
}

public enum EmbeddedResourceResource: Codable, Equatable, Sendable {
    case text(TextResourceContents)
    case blob(BlobResourceContents)

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        if case let .object(object) = value, object["text"] != nil {
            self = .text(try JSONDecoder().decode(TextResourceContents.self, from: JSONEncoder().encode(value)))
        } else {
            self = .blob(try JSONDecoder().decode(BlobResourceContents.self, from: JSONEncoder().encode(value)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(value): try value.encode(to: encoder)
        case let .blob(value): try value.encode(to: encoder)
        }
    }
}

public struct TextResourceContents: ACPMessage {
    public var meta: [String: JSONValue]?
    public var uri: String
    public var mimeType: String?
    public var text: String
    public init(meta: [String: JSONValue]? = nil, uri: String, mimeType: String? = nil, text: String) {
        self.meta = meta
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case uri; case mimeType; case text }
}

public struct BlobResourceContents: ACPMessage {
    public var meta: [String: JSONValue]?
    public var uri: String
    public var mimeType: String?
    public var blob: String
    public init(meta: [String: JSONValue]? = nil, uri: String, mimeType: String? = nil, blob: String) {
        self.meta = meta
        self.uri = uri
        self.mimeType = mimeType
        self.blob = blob
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case uri; case mimeType; case blob }
}

public struct Content: ACPMessage {
    public var meta: [String: JSONValue]?
    public var content: ContentBlock
    public init(meta: [String: JSONValue]? = nil, content: ContentBlock) {
        self.meta = meta
        self.content = content
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case content }
}

public typealias ContentChunk = Content

public struct SessionNotification: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId
    public var update: SessionUpdate

    public init(meta: [String: JSONValue]? = nil, sessionId: SessionId, update: SessionUpdate) {
        self.meta = meta
        self.sessionId = sessionId
        self.update = update
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionId
        case update
    }
}

public enum SessionUpdate: Codable, Equatable, Sendable {
    case userMessageChunk(ContentChunk)
    case agentMessageChunk(ContentChunk)
    case agentThoughtChunk(ContentChunk)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case plan(Plan)
    case availableCommandsUpdate(AvailableCommandsUpdate)
    case currentModeUpdate(CurrentModeUpdate)
    case configOptionUpdate(ConfigOptionUpdate)
    case sessionInfoUpdate(SessionInfoUpdate)
    case usageUpdate(UsageUpdate)
    case unknown(kind: String, payload: JSONValue)

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(object) = value, case let .string(kind)? = object["sessionUpdate"] else {
            self = .unknown(kind: "", payload: value)
            return
        }
        let data = try JSONEncoder().encode(value)
        let decoder = JSONDecoder()
        switch kind {
        case "user_message_chunk":
            self = .userMessageChunk(try decoder.decode(ContentChunk.self, from: data))
        case "agent_message_chunk":
            self = .agentMessageChunk(try decoder.decode(ContentChunk.self, from: data))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try decoder.decode(ContentChunk.self, from: data))
        case "tool_call":
            self = .toolCall(try decoder.decode(ToolCall.self, from: data))
        case "tool_call_update":
            self = .toolCallUpdate(try decoder.decode(ToolCallUpdate.self, from: data))
        case "plan":
            self = .plan(try decoder.decode(Plan.self, from: data))
        case "available_commands_update":
            self = .availableCommandsUpdate(try decoder.decode(AvailableCommandsUpdate.self, from: data))
        case "current_mode_update":
            self = .currentModeUpdate(try decoder.decode(CurrentModeUpdate.self, from: data))
        case "config_option_update":
            self = .configOptionUpdate(try decoder.decode(ConfigOptionUpdate.self, from: data))
        case "session_info_update":
            self = .sessionInfoUpdate(try decoder.decode(SessionInfoUpdate.self, from: data))
        case "usage_update":
            self = .usageUpdate(try decoder.decode(UsageUpdate.self, from: data))
        default:
            self = .unknown(kind: kind, payload: value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .userMessageChunk(chunk):
            try chunk.encodeWithSessionUpdate("user_message_chunk", to: encoder)
        case let .agentMessageChunk(chunk):
            try chunk.encodeWithSessionUpdate("agent_message_chunk", to: encoder)
        case let .agentThoughtChunk(chunk):
            try chunk.encodeWithSessionUpdate("agent_thought_chunk", to: encoder)
        case let .toolCall(toolCall):
            try toolCall.encodeWithSessionUpdate("tool_call", to: encoder)
        case let .toolCallUpdate(update):
            try update.encodeWithSessionUpdate("tool_call_update", to: encoder)
        case let .plan(plan):
            try plan.encodeWithSessionUpdate("plan", to: encoder)
        case let .availableCommandsUpdate(update):
            try update.encodeWithSessionUpdate("available_commands_update", to: encoder)
        case let .currentModeUpdate(update):
            try update.encodeWithSessionUpdate("current_mode_update", to: encoder)
        case let .configOptionUpdate(update):
            try update.encodeWithSessionUpdate("config_option_update", to: encoder)
        case let .sessionInfoUpdate(update):
            try update.encodeWithSessionUpdate("session_info_update", to: encoder)
        case let .usageUpdate(update):
            try update.encodeWithSessionUpdate("usage_update", to: encoder)
        case let .unknown(_, payload):
            try payload.encode(to: encoder)
        }
    }

    public var displayText: String? {
        switch self {
        case let .userMessageChunk(chunk), let .agentMessageChunk(chunk), let .agentThoughtChunk(chunk):
            return chunk.content.plainText
        case let .toolCall(toolCall):
            return toolCall.title
        case let .toolCallUpdate(update):
            return update.title
        case let .plan(plan):
            return plan.entries.map(\.content).joined(separator: "\n")
        default:
            return nil
        }
    }
}

public struct ToolCall: ACPMessage {
    public var meta: [String: JSONValue]?
    public var toolCallId: ToolCallId
    public var title: String
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public init(
        meta: [String: JSONValue]? = nil,
        toolCallId: ToolCallId,
        title: String,
        kind: ToolKind? = nil,
        status: ToolCallStatus? = nil,
        content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil
    ) {
        self.meta = meta
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case toolCallId
        case title
        case kind
        case status
        case content
        case locations
        case rawInput
        case rawOutput
    }
}

public struct ToolCallUpdate: ACPMessage {
    public var meta: [String: JSONValue]?
    public var toolCallId: ToolCallId
    public var title: String?
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var rawOutput: JSONValue?

    public init(
        meta: [String: JSONValue]? = nil,
        toolCallId: ToolCallId,
        title: String? = nil,
        kind: ToolKind? = nil,
        status: ToolCallStatus? = nil,
        content: [ToolCallContent]? = nil,
        locations: [ToolCallLocation]? = nil,
        rawInput: JSONValue? = nil,
        rawOutput: JSONValue? = nil
    ) {
        self.meta = meta
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case toolCallId
        case title
        case kind
        case status
        case content
        case locations
        case rawInput
        case rawOutput
    }
}

public enum ToolCallContent: Codable, Equatable, Sendable {
    case content(Content)
    case diff(Diff)
    case terminal(Terminal)
    case unknown(JSONValue)

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard case let .object(object) = value, case let .string(type)? = object["type"] else {
            self = .unknown(value)
            return
        }
        let data = try JSONEncoder().encode(value)
        switch type {
        case "content":
            self = .content(try JSONDecoder().decode(Content.self, from: data))
        case "diff":
            self = .diff(try JSONDecoder().decode(Diff.self, from: data))
        case "terminal":
            self = .terminal(try JSONDecoder().decode(Terminal.self, from: data))
        default:
            self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .content(value): try value.encodeWithType("content", to: encoder)
        case let .diff(value): try value.encodeWithType("diff", to: encoder)
        case let .terminal(value): try value.encodeWithType("terminal", to: encoder)
        case let .unknown(value): try value.encode(to: encoder)
        }
    }
}

public struct Diff: ACPMessage {
    public var meta: [String: JSONValue]?
    public var path: String
    public var oldText: String?
    public var newText: String
    public init(meta: [String: JSONValue]? = nil, path: String, oldText: String? = nil, newText: String) {
        self.meta = meta
        self.path = path
        self.oldText = oldText
        self.newText = newText
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case path; case oldText; case newText }
}

public struct Terminal: ACPMessage {
    public var meta: [String: JSONValue]?
    public var terminalId: String
    public init(meta: [String: JSONValue]? = nil, terminalId: String) {
        self.meta = meta
        self.terminalId = terminalId
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case terminalId }
}

public struct ToolCallLocation: ACPMessage {
    public var meta: [String: JSONValue]?
    public var path: String
    public var line: Int?
    public init(meta: [String: JSONValue]? = nil, path: String, line: Int? = nil) {
        self.meta = meta
        self.path = path
        self.line = line
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case path; case line }
}

public enum ToolCallStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

public enum ToolKind: String, Codable, Equatable, Sendable {
    case read
    case edit
    case delete
    case move
    case search
    case execute
    case think
    case fetch
    case switchMode = "switch_mode"
    case other
}

public enum StopReason: String, Codable, Equatable, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}

public struct Plan: ACPMessage {
    public var meta: [String: JSONValue]?
    public var entries: [PlanEntry]
    public init(meta: [String: JSONValue]? = nil, entries: [PlanEntry]) {
        self.meta = meta
        self.entries = entries
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case entries }
}

public struct PlanEntry: ACPMessage {
    public var meta: [String: JSONValue]?
    public var content: String
    public var priority: PlanEntryPriority?
    public var status: PlanEntryStatus
    public init(meta: [String: JSONValue]? = nil, content: String, priority: PlanEntryPriority? = nil, status: PlanEntryStatus) {
        self.meta = meta
        self.content = content
        self.priority = priority
        self.status = status
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case content; case priority; case status }
}

public enum PlanEntryPriority: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low
}

public enum PlanEntryStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct AvailableCommandsUpdate: ACPMessage {
    public var meta: [String: JSONValue]?
    public var availableCommands: [AvailableCommand]
    public init(meta: [String: JSONValue]? = nil, availableCommands: [AvailableCommand]) {
        self.meta = meta
        self.availableCommands = availableCommands
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case availableCommands }
}

public struct AvailableCommand: ACPMessage {
    public var meta: [String: JSONValue]?
    public var name: String
    public var description: String
    public var input: AvailableCommandInput?
    public init(meta: [String: JSONValue]? = nil, name: String, description: String, input: AvailableCommandInput? = nil) {
        self.meta = meta
        self.name = name
        self.description = description
        self.input = input
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case name; case description; case input }
}

public enum AvailableCommandInput: Codable, Equatable, Sendable {
    case unstructured(UnstructuredCommandInput)
    case raw(JSONValue)

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        if case let .object(object) = value, object["hint"] != nil {
            self = .unstructured(try JSONDecoder().decode(UnstructuredCommandInput.self, from: JSONEncoder().encode(value)))
        } else {
            self = .raw(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .unstructured(input): try input.encode(to: encoder)
        case let .raw(value): try value.encode(to: encoder)
        }
    }
}

public struct UnstructuredCommandInput: ACPMessage {
    public var meta: [String: JSONValue]?
    public var hint: String
    public init(meta: [String: JSONValue]? = nil, hint: String) {
        self.meta = meta
        self.hint = hint
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case hint }
}

public struct CurrentModeUpdate: ACPMessage {
    public var meta: [String: JSONValue]?
    public var currentModeId: SessionModeId
    public init(meta: [String: JSONValue]? = nil, currentModeId: SessionModeId) {
        self.meta = meta
        self.currentModeId = currentModeId
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case currentModeId }
}

public struct ConfigOptionUpdate: ACPMessage {
    public var meta: [String: JSONValue]?
    public var configOptions: [SessionConfigOption]
    public init(meta: [String: JSONValue]? = nil, configOptions: [SessionConfigOption]) {
        self.meta = meta
        self.configOptions = configOptions
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case configOptions }
}

public struct SessionInfoUpdate: ACPMessage {
    public var meta: [String: JSONValue]?
    public var title: String?
    public var updatedAt: String?
    /// Live session metadata the gateway reports (`session.info`): the active
    /// model/mode alias, working directory, and git branch. Optional so the ACP
    /// `session_info_update` path (which only carries title/updatedAt) still
    /// round-trips, and so a title-only update doesn't clobber them.
    public var model: String?
    public var cwd: String?
    public var branch: String?
    public init(
        meta: [String: JSONValue]? = nil,
        title: String? = nil,
        updatedAt: String? = nil,
        model: String? = nil,
        cwd: String? = nil,
        branch: String? = nil
    ) {
        self.meta = meta
        self.title = title
        self.updatedAt = updatedAt
        self.model = model
        self.cwd = cwd
        self.branch = branch
    }
    enum CodingKeys: String, CodingKey {
        case meta = "_meta"; case title; case updatedAt; case model; case cwd; case branch
    }
}

public struct UsageUpdate: ACPMessage {
    public var meta: [String: JSONValue]?
    public var size: Int
    public var used: Int
    public var cost: JSONValue?

    public init(meta: [String: JSONValue]? = nil, size: Int, used: Int, cost: JSONValue? = nil) {
        self.meta = meta
        self.size = size
        self.used = used
        self.cost = cost
    }

    enum CodingKeys: String, CodingKey { case meta = "_meta"; case size; case used; case cost }
}

public struct SessionInfo: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId
    public var cwd: String?
    public var title: String?
    public var updatedAt: String?
    public init(meta: [String: JSONValue]? = nil, sessionId: SessionId, cwd: String? = nil, title: String? = nil, updatedAt: String? = nil) {
        self.meta = meta
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case sessionId; case cwd; case title; case updatedAt }
}

public struct SessionModeState: ACPMessage {
    public var meta: [String: JSONValue]?
    public var currentModeId: SessionModeId
    public var availableModes: [SessionMode]
    public init(meta: [String: JSONValue]? = nil, currentModeId: SessionModeId, availableModes: [SessionMode]) {
        self.meta = meta
        self.currentModeId = currentModeId
        self.availableModes = availableModes
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case currentModeId; case availableModes }
}

public struct SessionMode: ACPMessage {
    public var meta: [String: JSONValue]?
    public var id: SessionModeId
    public var name: String
    public var description: String?
    public init(meta: [String: JSONValue]? = nil, id: SessionModeId, name: String, description: String? = nil) {
        self.meta = meta
        self.id = id
        self.name = name
        self.description = description
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case id; case name; case description }
}

public struct SessionConfigOption: Codable, Equatable, Sendable {
    public var value: JSONValue
    public init(value: JSONValue) { self.value = value }
    public init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

public struct SetSessionModeRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId
    public var modeId: SessionModeId
    public init(meta: [String: JSONValue]? = nil, sessionId: SessionId, modeId: SessionModeId) {
        self.meta = meta
        self.sessionId = sessionId
        self.modeId = modeId
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case sessionId; case modeId }
}

public struct SetSessionModeResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var modes: SessionModeState
    public init(meta: [String: JSONValue]? = nil, modes: SessionModeState) {
        self.meta = meta
        self.modes = modes
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case modes }
}

public struct SetSessionConfigOptionRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId
    public var configId: SessionConfigId
    public var value: SessionConfigValueId
    public init(meta: [String: JSONValue]? = nil, sessionId: SessionId, configId: SessionConfigId, value: SessionConfigValueId) {
        self.meta = meta
        self.sessionId = sessionId
        self.configId = configId
        self.value = value
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case sessionId; case configId; case value }
}

public struct SetSessionConfigOptionResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var configOptions: [SessionConfigOption]
    public init(meta: [String: JSONValue]? = nil, configOptions: [SessionConfigOption]) {
        self.meta = meta
        self.configOptions = configOptions
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case configOptions }
}

public struct ReadTextFileRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var path: String
    public var line: Int?
    public var limit: Int?
    public init(meta: [String: JSONValue]? = nil, path: String, line: Int? = nil, limit: Int? = nil) {
        self.meta = meta
        self.path = path
        self.line = line
        self.limit = limit
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case path; case line; case limit }
}

public struct ReadTextFileResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var content: String
    public init(meta: [String: JSONValue]? = nil, content: String) {
        self.meta = meta
        self.content = content
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case content }
}

public struct WriteTextFileRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var path: String
    public var content: String
    public init(meta: [String: JSONValue]? = nil, path: String, content: String) {
        self.meta = meta
        self.path = path
        self.content = content
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case path; case content }
}

public struct WriteTextFileResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public init(meta: [String: JSONValue]? = nil) { self.meta = meta }
    enum CodingKeys: String, CodingKey { case meta = "_meta" }
}

public enum RequestPermissionOutcome: Codable, Equatable, Sendable {
    case cancelled
    case selected(SelectedPermissionOutcome)
    case raw(JSONValue)

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        if case let .object(object) = value,
           case let .string(outcome)? = object["outcome"] {
            switch outcome {
            case "cancelled":
                self = .cancelled
            case "selected":
                self = .selected(try JSONDecoder().decode(SelectedPermissionOutcome.self, from: JSONEncoder().encode(value)))
            default:
                self = .raw(value)
            }
        } else if case let .object(object) = value, object["optionId"] != nil {
            self = .selected(try JSONDecoder().decode(SelectedPermissionOutcome.self, from: JSONEncoder().encode(value)))
        } else {
            self = .raw(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .cancelled:
            try JSONValue.object(["outcome": .string("cancelled")]).encode(to: encoder)
        case let .selected(outcome):
            try outcome.encodeWithOutcome("selected", to: encoder)
        case let .raw(value): try value.encode(to: encoder)
        }
    }
}

public struct SelectedPermissionOutcome: ACPMessage {
    public var meta: [String: JSONValue]?
    public var optionId: PermissionOptionId
    public init(meta: [String: JSONValue]? = nil, optionId: PermissionOptionId) {
        self.meta = meta
        self.optionId = optionId
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case optionId }
}

public struct RequestPermissionRequest: ACPMessage {
    public var meta: [String: JSONValue]?
    public var sessionId: SessionId
    public var toolCall: ToolCallUpdate
    public var options: [PermissionOption]

    public init(
        meta: [String: JSONValue]? = nil,
        sessionId: SessionId,
        toolCall: ToolCallUpdate,
        options: [PermissionOption]
    ) {
        self.meta = meta
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case sessionId
        case toolCall
        case options
    }
}

public struct RequestPermissionResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var outcome: RequestPermissionOutcome
    public init(meta: [String: JSONValue]? = nil, outcome: RequestPermissionOutcome) {
        self.meta = meta
        self.outcome = outcome
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case outcome }
}

public struct PermissionOption: ACPMessage {
    public var meta: [String: JSONValue]?
    public var optionId: PermissionOptionId
    public var name: String
    public var kind: PermissionOptionKind

    public init(meta: [String: JSONValue]? = nil, optionId: PermissionOptionId, name: String, kind: PermissionOptionKind) {
        self.meta = meta
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case meta = "_meta"
        case optionId
        case name
        case kind
    }
}

public enum PermissionOptionKind: String, Codable, Equatable, Sendable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case rejectOnce = "reject_once"
    case rejectAlways = "reject_always"
}

public struct CreateTerminalRequest: Codable, Equatable, Sendable {
    public var value: JSONValue
    public init(value: JSONValue) { self.value = value }
    public init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

public struct CreateTerminalResponse: Codable, Equatable, Sendable {
    public var value: JSONValue
    public init(value: JSONValue) { self.value = value }
    public init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

public typealias TerminalOutputRequest = CreateTerminalRequest
public typealias TerminalOutputResponse = WriteTextFileResponse
public typealias WaitForTerminalExitRequest = CreateTerminalRequest
public struct WaitForTerminalExitResponse: ACPMessage {
    public var meta: [String: JSONValue]?
    public var exitStatus: TerminalExitStatus
    public init(meta: [String: JSONValue]? = nil, exitStatus: TerminalExitStatus) {
        self.meta = meta
        self.exitStatus = exitStatus
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case exitStatus }
}
public typealias KillTerminalRequest = CreateTerminalRequest
public typealias KillTerminalResponse = WriteTextFileResponse
public typealias ReleaseTerminalRequest = CreateTerminalRequest
public typealias ReleaseTerminalResponse = WriteTextFileResponse

public struct TerminalExitStatus: ACPMessage {
    public var meta: [String: JSONValue]?
    public var exitCode: Int?
    public var signal: String?
    public init(meta: [String: JSONValue]? = nil, exitCode: Int? = nil, signal: String? = nil) {
        self.meta = meta
        self.exitCode = exitCode
        self.signal = signal
    }
    enum CodingKeys: String, CodingKey { case meta = "_meta"; case exitCode; case signal }
}

public struct ExtRequest: Codable, Equatable, Sendable {
    public var value: JSONValue
    public init(value: JSONValue) { self.value = value }
    public init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

public typealias ExtResponse = ExtRequest
public typealias ExtNotification = ExtRequest
public typealias AgentRequest = ExtRequest
public typealias AgentResponse = ExtRequest
public typealias AgentNotification = ExtRequest
public typealias ClientRequest = ExtRequest
public typealias ClientResponse = ExtRequest
public typealias ClientNotification = ExtRequest

private enum TypeCodingKeys: String, CodingKey {
    case type
}

private enum SessionUpdateCodingKeys: String, CodingKey {
    case sessionUpdate
}

private enum ToolCallContentCodingKeys: String, CodingKey {
    case type
}

private extension Encodable {
    func encodeAdding(_ key: String, value discriminator: String, to encoder: Encoder) throws {
        var value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
        if case var .object(object) = value {
            object[key] = .string(discriminator)
            value = .object(object)
        }
        try value.encode(to: encoder)
    }

    func encodeWithSessionUpdate(_ sessionUpdate: String, to encoder: Encoder) throws {
        try encodeAdding("sessionUpdate", value: sessionUpdate, to: encoder)
    }

    func encodeWithOutcome(_ outcome: String, to encoder: Encoder) throws {
        try encodeAdding("outcome", value: outcome, to: encoder)
    }
}

private extension Content {
    func encodeWithType(_ type: String, to encoder: Encoder) throws {
        try encodeAdding("type", value: type, to: encoder)
    }
}

private extension Diff {
    func encodeWithType(_ type: String, to encoder: Encoder) throws {
        try encodeAdding("type", value: type, to: encoder)
    }
}

private extension Terminal {
    func encodeWithType(_ type: String, to encoder: Encoder) throws {
        try encodeAdding("type", value: type, to: encoder)
    }
}
