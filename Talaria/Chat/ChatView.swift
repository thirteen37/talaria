import HermesKit
import SwiftUI

struct ChatView: View {
    @State private var viewModel = LocalChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if viewModel.messages.isEmpty {
                            ContentUnavailableView("No Session", systemImage: "bubble.left.and.bubble.right")
                                .frame(maxWidth: .infinity, minHeight: 360)
                        } else {
                            ForEach(viewModel.messages) { message in
                                TranscriptRow(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: viewModel.messages) { _, messages in
                    guard let last = messages.last else {
                        return
                    }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }

            if let status = viewModel.statusText {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(viewModel.hasError ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
            }

            Composer(
                prompt: $viewModel.prompt,
                isSending: viewModel.isSending,
                send: { Task { await viewModel.sendPrompt() } },
                cancel: { Task { await viewModel.cancel() } }
            )
        }
        .navigationTitle("Chat")
        .onDisappear {
            Task { await viewModel.shutdown() }
        }
    }
}

private struct TranscriptRow: View {
    let message: ChatTranscriptMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.kind.systemImage)
                .foregroundStyle(message.kind.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(message.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(message.kind.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct Composer: View {
    @Binding var prompt: String
    var isSending: Bool
    var send: () -> Void
    var cancel: () -> Void

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message Hermes", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        return .ignored
                    }
                    send()
                    return .handled
                }

            if isSending {
                Button(action: cancel) {
                    Image(systemName: "stop.fill")
                }
                .help("Cancel")
            } else {
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .help("Send")
                .disabled(trimmedPrompt.isEmpty)
            }
        }
        .padding(12)
    }
}

@MainActor
@Observable
private final class LocalChatViewModel {
    var prompt = ""
    var messages: [ChatTranscriptMessage] = []
    var isSending = false
    var statusText: String?
    var hasError = false

    private var transport: LocalProcessTransport?
    private var client: HermesClient?
    private var sessionId: SessionId?
    private var notificationTask: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?
    private var currentUserStreamMessageId: UUID?
    private var currentAgentMessageId: UUID?
    private var currentThoughtMessageId: UUID?
    private var toolMessageIds: [ToolCallId: UUID] = [:]
    private var toolTitles: [ToolCallId: String] = [:]
    private var sessionCwd = FileManager.default.homeDirectoryForCurrentUser.path

    func sendPrompt() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else {
            return
        }

        prompt = ""
        currentUserStreamMessageId = append(kind: .user, text: text)
        resetStreamingMessages()
        currentUserStreamMessageId = messages.last?.id
        isSending = true
        statusText = "Connecting to Hermes..."
        hasError = false

        promptTask = Task {
            do {
                let client = try await ensureClient()
                let sessionId = try await ensureSession(client: client)
                statusText = "Hermes is working in \(sessionCwd)..."
                let response = try await client.prompt(sessionId: sessionId, content: text)
                statusText = "Stopped: \(response.stopReason.rawValue)"
            } catch is CancellationError {
                statusText = "Cancelled"
            } catch {
                hasError = true
                statusText = errorMessage(for: error)
            }
            isSending = false
        }
    }

    func cancel() async {
        promptTask?.cancel()
        guard let client, let sessionId else {
            isSending = false
            statusText = "Cancelled"
            return
        }

        do {
            try await client.cancel(sessionId: sessionId)
            statusText = "Cancellation requested"
        } catch {
            hasError = true
            statusText = errorMessage(for: error)
        }
    }

    func shutdown() async {
        notificationTask?.cancel()
        promptTask?.cancel()
        await client?.close()
        client = nil
        transport = nil
        sessionId = nil
        isSending = false
        resetStreamingMessages()
        toolMessageIds.removeAll()
        toolTitles.removeAll()
    }

    private func ensureClient() async throws -> HermesClient {
        if let client {
            return client
        }

        #if os(macOS)
        let transport = LocalProcessTransport()
        try transport.start()
        self.transport = transport

        let client = HermesClient(transport: transport)
        self.client = client

        let task = Task.detached { [weak self, notifications = client.notifications] in
            do {
                for try await notification in notifications {
                    await self?.handle(notification: notification)
                }
            } catch is CancellationError {
                // Normal shutdown cancels the notification task.
            } catch {
                await self?.handleNotificationError(error)
            }
        }
        notificationTask = task

        do {
            _ = try await client.initialize()
            statusText = "Connected"
            return client
        } catch {
            task.cancel()
            notificationTask = nil
            self.client = nil
            self.transport = nil
            await client.close()
            throw error
        }
        #else
        throw TransportError.unsupportedPlatform
        #endif
    }

    private func ensureSession(client: HermesClient) async throws -> SessionId {
        if let sessionId {
            return sessionId
        }

        let response = try await client.newSession(cwd: sessionCwd, mcpServers: [])
        sessionId = response.sessionId
        statusText = "Session cwd: \(sessionCwd)"
        return response.sessionId
    }

    private func handle(notification: HermesNotification) {
        switch notification {
        case let .sessionUpdate(notification):
            switch notification.update {
            case let .userMessageChunk(chunk):
                appendStreaming(kind: .user, text: chunk.content.plainText ?? "", stream: .user)
            case let .agentMessageChunk(chunk):
                appendStreaming(kind: .agent, text: chunk.content.plainText ?? "", stream: .agent)
            case let .agentThoughtChunk(chunk):
                appendStreaming(kind: .thought, text: chunk.content.plainText ?? "", stream: .thought)
            case let .toolCall(toolCall):
                resetStreamingMessages()
                upsertToolMessage(id: toolCall.toolCallId, title: toolCall.title, status: toolCall.status)
            case let .toolCallUpdate(update):
                resetStreamingMessages()
                upsertToolMessage(id: update.toolCallId, title: update.title, status: update.status)
            default:
                if let text = notification.update.displayText {
                    resetStreamingMessages()
                    append(kind: .event, text: text)
                }
            }
        case let .raw(method, _):
            resetStreamingMessages()
            append(kind: .event, text: method)
        case let .request(id, method, _):
            resetStreamingMessages()
            append(kind: .event, text: "Unsupported Hermes request: \(method)")
            Task { [client] in
                try? await client?.respond(
                    id: id,
                    error: JSONRPCError(code: -32601, message: "Talaria does not support \(method) yet")
                )
            }
        }
    }

    private func handleNotificationError(_ error: Error) {
        if !hasError {
            hasError = true
            statusText = errorMessage(for: error)
        }
    }

    @discardableResult
    private func append(kind: ChatTranscriptMessage.Kind, text: String, toolCallId: ToolCallId? = nil) -> UUID? {
        guard !text.isEmpty else {
            return nil
        }
        let message = ChatTranscriptMessage(kind: kind, text: text, toolCallId: toolCallId)
        messages.append(message)
        return message.id
    }

    private func appendStreaming(kind: ChatTranscriptMessage.Kind, text: String, stream: StreamKind) {
        guard !text.isEmpty else {
            return
        }

        if let id = currentMessageId(for: stream),
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += text
            return
        }

        let id = append(kind: kind, text: text)
        setCurrentMessageId(id, for: stream)
    }

    private func upsertToolMessage(id toolCallId: ToolCallId, title: String?, status: ToolCallStatus?) {
        if let title {
            toolTitles[toolCallId] = title
        }

        let displayTitle = title ?? toolTitles[toolCallId] ?? toolCallId
        let text = [displayTitle, status.map { "(\($0.rawValue))" }]
            .compactMap { $0 }
            .joined(separator: " ")

        if let messageId = toolMessageIds[toolCallId],
           let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].text = text
        } else if let messageId = append(kind: .tool, text: text, toolCallId: toolCallId) {
            toolMessageIds[toolCallId] = messageId
        }
    }

    private func currentMessageId(for stream: StreamKind) -> UUID? {
        switch stream {
        case .user: currentUserStreamMessageId
        case .agent: currentAgentMessageId
        case .thought: currentThoughtMessageId
        }
    }

    private func setCurrentMessageId(_ id: UUID?, for stream: StreamKind) {
        switch stream {
        case .user: currentUserStreamMessageId = id
        case .agent: currentAgentMessageId = id
        case .thought: currentThoughtMessageId = id
        }
    }

    private func resetStreamingMessages() {
        currentUserStreamMessageId = nil
        currentAgentMessageId = nil
        currentThoughtMessageId = nil
    }

    private func errorMessage(for error: Error) -> String {
        if case TransportError.processDidNotStart = error {
            return "Hermes could not be launched. Install Hermes or make sure `hermes` is on PATH."
        }
        if case TransportError.stdinClosed = error {
            return "Hermes exited before accepting the request. Install Hermes or run `hermes acp` from a shell to inspect the error."
        }
        if case let TransportError.writeFailed(message) = error {
            return "Hermes write failed: \(message)"
        }
        return error.localizedDescription
    }
}

private enum StreamKind {
    case user
    case agent
    case thought
}

private struct ChatTranscriptMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case agent
        case thought
        case tool
        case event

        var title: String {
            switch self {
            case .user: "You"
            case .agent: "Hermes"
            case .thought: "Thinking"
            case .tool: "Tool"
            case .event: "Event"
            }
        }

        var systemImage: String {
            switch self {
            case .user: "person.crop.circle"
            case .agent: "sparkles"
            case .thought: "brain.head.profile"
            case .tool: "wrench.and.screwdriver"
            case .event: "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .user: .blue
            case .agent: .green
            case .thought: .purple
            case .tool: .orange
            case .event: .secondary
            }
        }

        var background: Color {
            switch self {
            case .user: Color.blue.opacity(0.08)
            case .agent: Color.green.opacity(0.08)
            case .thought: Color.purple.opacity(0.08)
            case .tool: Color.orange.opacity(0.08)
            case .event: Color.gray.opacity(0.08)
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var text: String
    var toolCallId: ToolCallId?
}
