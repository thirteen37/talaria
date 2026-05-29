import Foundation
import Testing
@testable import HermesKit

// End-to-end smoke against the real `hermes acp` binary. These tests spawn a
// live `hermes` process and (in the prompt case) drive a real model turn, so
// they are slow, network-dependent, and have no guaranteed instance in CI or
// on a fresh checkout. They are therefore OPT-IN: the suite is skipped unless
// `HERMES_LIVE_TESTS=1` is set in the environment. Run them manually with
// `HERMES_LIVE_TESTS=1 swift test --filter HermesACPLiveSmokeTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HERMES_LIVE_TESTS"] == "1"))
struct HermesACPLiveSmokeTests {
    @Test
    func initializeAndNewSessionAgainstRealHermes() async throws {
        guard let hermesPath = which("hermes") else {
            return
        }

        let transport = LocalProcessTransport(hermesPath: hermesPath)
        try transport.start()
        let client = HermesClient(transport: transport)

        do {
            let initialize = try await withThrowingTimeout(seconds: 30) {
                try await client.initialize()
            }
            print("[acp] protocolVersion=\(initialize.protocolVersion)")
            print("[acp] agentInfo=\(String(describing: initialize.agentInfo))")
            print("[acp] loadSession=\(String(describing: initialize.agentCapabilities?.loadSession))")
            print("[acp] sessionCapabilities=\(String(describing: initialize.agentCapabilities?.sessionCapabilities))")
            print("[acp] promptCapabilities=\(String(describing: initialize.agentCapabilities?.promptCapabilities))")

            let session = try await withThrowingTimeout(seconds: 30) {
                try await client.newSession(cwd: FileManager.default.currentDirectoryPath)
            }
            print("[acp] newSession.sessionId=\(session.sessionId)")
            #expect(!session.sessionId.isEmpty)
        } catch {
            print("[acp] ERROR: \(error)")
            print("[acp] stderr tail:\n\(transport.recentStderr().suffix(2000))")
            Issue.record("ACP smoke failed: \(error)")
        }

        await client.close()
    }

    @Test
    func promptStreamsAgainstRealHermes() async throws {
        guard let hermesPath = which("hermes") else {
            return
        }

        let transport = LocalProcessTransport(hermesPath: hermesPath)
        try transport.start()
        let client = HermesClient(transport: transport)

        // Drain notifications in the background so we can summarise them at the end.
        let collector = NotificationCollector()
        let observer = Task<Void, Error> {
            for try await notification in client.notifications {
                await collector.record(notification)
            }
        }

        do {
            _ = try await withThrowingTimeout(seconds: 30) { try await client.initialize() }
            let session = try await withThrowingTimeout(seconds: 30) {
                try await client.newSession(cwd: FileManager.default.currentDirectoryPath)
            }
            print("[acp] session=\(session.sessionId)")

            let response = try await withThrowingTimeout(seconds: 120) {
                try await client.prompt(sessionId: session.sessionId, content: "Reply with the single word: pong")
            }
            print("[acp] stopReason=\(response.stopReason.rawValue)")
        } catch {
            print("[acp] ERROR: \(error)")
            print("[acp] stderr tail:\n\(transport.recentStderr().suffix(2000))")
            Issue.record("prompt smoke failed: \(error)")
        }

        await client.close()
        observer.cancel()

        let snapshot = await collector.snapshot()
        print("[acp] notifications=\(snapshot.total)")
        print("[acp] kinds=\(snapshot.kinds)")
        if !snapshot.agentText.isEmpty {
            print("[acp] agentText=\(snapshot.agentText.prefix(400))")
        }
        if !snapshot.toolCalls.isEmpty {
            print("[acp] toolCalls=\(snapshot.toolCalls)")
        }
        if !snapshot.serverRequests.isEmpty {
            print("[acp] serverRequests=\(snapshot.serverRequests)")
        }
        if !snapshot.unknownUpdates.isEmpty {
            print("[acp] unknownUpdates=\(snapshot.unknownUpdates)")
        }
    }
}

private actor NotificationCollector {
    struct Snapshot {
        var total: Int
        var kinds: [String: Int]
        var agentText: String
        var toolCalls: [String]
        var serverRequests: [String]
        var unknownUpdates: [String]
    }

    private var total = 0
    private var kinds: [String: Int] = [:]
    private var agentText = ""
    private var toolCalls: [String] = []
    private var serverRequests: [String] = []
    private var unknownUpdates: [String] = []

    func record(_ notification: HermesNotification) {
        total += 1
        switch notification {
        case let .sessionUpdate(update):
            switch update.update {
            case let .agentMessageChunk(chunk):
                bump("agent_message_chunk")
                if let text = chunk.content.plainText { agentText += text }
            case let .agentThoughtChunk(chunk):
                bump("agent_thought_chunk")
                _ = chunk
            case let .userMessageChunk(chunk):
                bump("user_message_chunk")
                _ = chunk
            case let .toolCall(call):
                bump("tool_call")
                toolCalls.append("\(call.title) [\(call.kind?.rawValue ?? "?")] -> \(call.status?.rawValue ?? "?")")
            case let .toolCallUpdate(updateRow):
                bump("tool_call_update")
                let title = updateRow.title ?? "(no title)"
                toolCalls.append("update: \(title) -> \(updateRow.status?.rawValue ?? "?")")
            case .availableCommandsUpdate:
                bump("available_commands_update")
            case .plan:
                bump("plan")
            case .currentModeUpdate:
                bump("current_mode_update")
            case .configOptionUpdate:
                bump("config_option_update")
            case .sessionInfoUpdate:
                bump("session_info_update")
            case let .usageUpdate(usage):
                bump("usage_update")
                _ = usage
            case let .unknown(kind, _):
                bump("unknown:\(kind)")
                unknownUpdates.append(kind)
            }
        case let .permissionRequest(event):
            bump("permission_request")
            serverRequests.append("permission: \(event.request.toolCall.title ?? "?")")
        case let .clientRequestError(_, method, message):
            bump("client_request_error")
            serverRequests.append("error: \(method): \(message)")
        case let .raw(method, _):
            bump("raw:\(method)")
        case let .request(_, method, _):
            bump("server_request:\(method)")
            serverRequests.append("request: \(method)")
        }
    }

    private func bump(_ key: String) {
        kinds[key, default: 0] += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            total: total,
            kinds: kinds,
            agentText: agentText,
            toolCalls: toolCalls,
            serverRequests: serverRequests,
            unknownUpdates: unknownUpdates
        )
    }
}

private func which(_ tool: String) -> String? {
    let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in pathEnv.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(tool)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
    }
    return nil
}

private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private struct TimeoutError: Error {}
