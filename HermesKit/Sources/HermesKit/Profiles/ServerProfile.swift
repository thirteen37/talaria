import Foundation

public struct ServerProfile: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case local
        case ssh
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var host: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    public var hermesPath: String
    public var hermesHome: String?
    public var env: [String: String]
    public var version: HermesVersion?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        host: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        hermesPath: String = "hermes",
        hermesHome: String? = nil,
        env: [String: String] = [:],
        version: HermesVersion? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.hermesPath = hermesPath
        self.hermesHome = hermesHome
        self.env = env
        self.version = version
    }
}
