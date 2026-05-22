import Foundation

public enum HermesClientError: Error, Equatable, Sendable {
    case missingResponseResult(JSONRPCID)
    case unexpectedNotification(String)
    case transportClosed
}

public enum HermesNotification: Equatable, Sendable {
    case sessionUpdate(SessionNotification)
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case raw(method: String, params: JSONValue?)
}

public actor HermesClient {
    public nonisolated let notifications: AsyncThrowingStream<HermesNotification, Error>

    private let transport: any Transport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let notificationContinuation: AsyncThrowingStream<HermesNotification, Error>.Continuation
    private var framer = JSONRPCFramer()
    private var nextID = 1
    private var pending: [JSONRPCID: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false

    public init(transport: any Transport) {
        self.transport = transport

        var captured: AsyncThrowingStream<HermesNotification, Error>.Continuation?
        self.notifications = AsyncThrowingStream { continuation in
            captured = continuation
        }
        self.notificationContinuation = captured!

        Task { await self.readLoop() }
    }

    public func request<Params: Codable & Sendable, Result: Codable & Sendable>(
        method: String,
        params: Params? = nil,
        as resultType: Result.Type = Result.self
    ) async throws -> Result {
        let id = JSONRPCID.number(nextID)
        nextID += 1

        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONRPCFramer.encode(request, encoder: encoder)

        let resultValue = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    do {
                        try await transport.send(data)
                    } catch {
                        self.failPending(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failPending(id: id, error: CancellationError()) }
        }

        let resultData = try encoder.encode(resultValue)
        return try decoder.decode(Result.self, from: resultData)
    }

    public func sendNotification<Params: Codable & Sendable>(
        method: String,
        params: Params? = nil
    ) async throws {
        let notification = JSONRPCNotification(method: method, params: params)
        try await transport.send(JSONRPCFramer.encode(notification, encoder: encoder))
    }

    public func respond<Result: Codable & Sendable>(id: JSONRPCID, result: Result) async throws {
        try await transport.send(JSONRPCFramer.encode(JSONRPCResponse(id: id, result: result), encoder: encoder))
    }

    public func respond(id: JSONRPCID, error: JSONRPCError) async throws {
        try await transport.send(JSONRPCFramer.encode(JSONRPCResponse<JSONValue>(id: id, error: error), encoder: encoder))
    }

    public func initialize(
        protocolVersion: ProtocolVersion = 1,
        clientInfo: Implementation = Implementation(name: "Talaria", version: "1.0"),
        clientCapabilities: ClientCapabilities = ClientCapabilities()
    ) async throws -> InitializeResponse {
        let params = InitializeRequest(
            protocolVersion: protocolVersion,
            clientCapabilities: clientCapabilities,
            clientInfo: clientInfo
        )
        return try await request(method: ACPMethod.initialize, params: params, as: InitializeResponse.self)
    }

    @discardableResult
    public func initialize(version: String) async throws -> InitializeResponse {
        try await initialize(clientInfo: Implementation(name: "Talaria", version: version))
    }

    public func newSession(cwd: String, mcpServers: [McpServer] = []) async throws -> NewSessionResponse {
        try await request(
            method: ACPMethod.sessionNew,
            params: NewSessionRequest(cwd: cwd, mcpServers: mcpServers),
            as: NewSessionResponse.self
        )
    }

    public func prompt(sessionId: SessionId, content: [ContentBlock]) async throws -> PromptResponse {
        try await request(
            method: ACPMethod.sessionPrompt,
            params: PromptRequest(sessionId: sessionId, prompt: content),
            as: PromptResponse.self
        )
    }

    public func prompt(sessionId: SessionId, content: String) async throws -> PromptResponse {
        try await prompt(sessionId: sessionId, content: [.text(content)])
    }

    public func cancel(sessionId: SessionId) async throws {
        try await sendNotification(method: ACPMethod.sessionCancel, params: CancelNotification(sessionId: sessionId))
    }

    public func close() async {
        guard !closed else {
            return
        }
        closed = true
        await transport.close()
        finish(error: nil)
    }

    private func readLoop() async {
        do {
            for try await chunk in transport.inbound {
                let frames = try framer.append(chunk)
                for frame in frames {
                    await handleFrame(frame)
                }
            }

            if let partial = framer.finish() {
                await handleFrame(partial)
            }
            finish(error: closed ? nil : HermesClientError.transportClosed)
        } catch {
            finish(error: closed ? nil : error)
        }
    }

    private func handleFrame(_ frame: Data) async {
        guard !frame.isEmpty else {
            return
        }

        guard let message = try? decoder.decode(JSONRPCInboundMessage.self, from: frame) else {
            return
        }

        if let method = message.method {
            if let id = message.id {
                notificationContinuation.yield(.request(id: id, method: method, params: message.params))
            } else {
                handleNotification(method: method, params: message.params)
            }
            return
        }

        guard let id = message.id else {
            return
        }

        if let error = message.error {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        } else if let result = message.result {
            pending.removeValue(forKey: id)?.resume(returning: result)
        } else if message.hasResult {
            pending.removeValue(forKey: id)?.resume(returning: .null)
        } else {
            pending.removeValue(forKey: id)?.resume(throwing: HermesClientError.missingResponseResult(id))
        }
    }

    private func handleNotification(method: String, params: JSONValue?) {
        if method == ACPMethod.sessionUpdate, let params {
            do {
                let data = try encoder.encode(params)
                let notification = try decoder.decode(SessionNotification.self, from: data)
                notificationContinuation.yield(.sessionUpdate(notification))
            } catch {
                notificationContinuation.yield(.raw(method: method, params: params))
            }
        } else {
            notificationContinuation.yield(.raw(method: method, params: params))
        }
    }

    private func failPending(id: JSONRPCID, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func finish(error: Error?) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error ?? HermesClientError.transportClosed)
        }

        if let error {
            notificationContinuation.finish(throwing: error)
        } else {
            notificationContinuation.finish()
        }
    }
}
