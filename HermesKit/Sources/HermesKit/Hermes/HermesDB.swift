import Foundation

public struct HermesSessionSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: Date?

    public init(id: String, title: String, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

public struct HermesDBConfiguration: Equatable, Sendable {
    public var databaseURL: URL
    public var readOnly: Bool

    public init(databaseURL: URL, readOnly: Bool = true) {
        self.databaseURL = databaseURL
        self.readOnly = readOnly
    }
}

public struct HermesDB: Sendable {
    public var configuration: HermesDBConfiguration

    public init(configuration: HermesDBConfiguration) {
        self.configuration = configuration
    }
}
