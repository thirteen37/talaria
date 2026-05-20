import Foundation

public actor HermesClient {
    private let transport: any Transport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var nextID = 1

    public init(transport: any Transport) {
        self.transport = transport
    }

    @discardableResult
    public func sendRequest<Params: Codable & Sendable>(
        method: String,
        params: Params? = nil
    ) async throws -> JSONRPCID {
        let id = JSONRPCID.number(nextID)
        nextID += 1
        let request = JSONRPCRequest(id: id, method: method, params: params)
        try await transport.send(JSONRPCFramer.encode(request, encoder: encoder))
        return id
    }

    public func sendNotification<Params: Codable & Sendable>(
        method: String,
        params: Params? = nil
    ) async throws {
        let notification = JSONRPCNotification(method: method, params: params)
        try await transport.send(JSONRPCFramer.encode(notification, encoder: encoder))
    }

    public func initialize(version: String) async throws -> JSONRPCID {
        let params = ACPInitializeParams(
            clientInfo: ACPClientInfo(version: version),
            protocolVersion: "1"
        )
        return try await sendRequest(method: ACPMethod.initialize, params: params)
    }
}
