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

            StatusBar(
                statusText: viewModel.statusText,
                hasError: viewModel.hasError,
                isSending: viewModel.isSending,
                turnStartDate: viewModel.turnStartDate,
                gitBranch: viewModel.gitBranch
            )

            Composer(
                prompt: $viewModel.prompt,
                isSending: viewModel.isSending,
                isBlocked: viewModel.pendingPermission != nil,
                availableCommands: viewModel.availableCommands,
                send: { Task { await viewModel.sendPrompt() } },
                cancel: { Task { await viewModel.cancel() } }
            )
        }
        .navigationTitle("Chat")
        .sheet(item: $viewModel.pendingPermission) { permission in
            PermissionPrompt(
                state: permission,
                select: { option in
                    Task { await viewModel.resolvePermission(.selected(SelectedPermissionOutcome(optionId: option.optionId))) }
                },
                cancel: {
                    Task { await viewModel.resolvePermission(.cancelled) }
                }
            )
        }
        .onDisappear {
            Task { await viewModel.shutdown() }
        }
    }
}

@MainActor
@Observable
final class LocalChatViewModel {
    var prompt = ""
    var messages: [ChatTranscriptMessage] = []
    var isSending = false
    var statusText: String?
    var hasError = false
    var pendingPermission: PermissionPromptState?
    var availableCommands: [AvailableCommand] = []
    var gitBranch: String?
    var turnStartDate: Date?

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
        guard !text.isEmpty, !isSending, pendingPermission == nil else {
            return
        }

        prompt = ""
        _ = append(kind: .user, text: text)
        resetStreamingMessages()
        currentUserStreamMessageId = messages.last?.id
        isSending = true
        turnStartDate = Date()
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
            turnStartDate = nil
        }
    }

    func cancel() async {
        promptTask?.cancel()

        if pendingPermission != nil {
            await resolvePermission(.cancelled)
        }

        guard let client, let sessionId else {
            isSending = false
            turnStartDate = nil
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

    func resolvePermission(_ outcome: PermissionOutcome) async {
        guard let permission = pendingPermission else {
            return
        }

        pendingPermission = nil
        applyLocalToolStatus(for: outcome, permission: permission)
        await permission.respond(outcome)
        statusText = "Permission response sent"
    }

    private func applyLocalToolStatus(for outcome: PermissionOutcome, permission: PermissionPromptState) {
        let toolCallId = permission.request.toolCall.toolCallId
        switch outcome {
        case .cancelled:
            setToolStatus(.failed, for: toolCallId)
        case let .selected(selection):
            guard let option = permission.request.options.first(where: { $0.optionId == selection.optionId }) else {
                return
            }
            switch option.kind {
            case .allowOnce, .allowAlways:
                setToolStatus(nil, for: toolCallId)
            case .rejectOnce, .rejectAlways:
                setToolStatus(.failed, for: toolCallId)
            }
        case .raw:
            return
        }
    }

    private func setToolStatus(_ status: ToolCallStatus?, for toolCallId: ToolCallId) {
        guard let messageId = toolMessageIds[toolCallId],
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        let displayTitle = messages[index].toolTitle ?? toolTitles[toolCallId] ?? toolCallId
        messages[index].toolStatus = status
        messages[index].text = [displayTitle, status.map { "(\($0.rawValue))" }]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    func shutdown() async {
        notificationTask?.cancel()
        promptTask?.cancel()
        if pendingPermission != nil {
            await resolvePermission(.cancelled)
        }
        await client?.close()
        client = nil
        transport = nil
        sessionId = nil
        isSending = false
        turnStartDate = nil
        resetStreamingMessages()
        toolMessageIds.removeAll()
        toolTitles.removeAll()
        availableCommands.removeAll()
        gitBranch = nil
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
        loadGitBranch()
        return response.sessionId
    }

    private func loadGitBranch() {
        let cwd = sessionCwd
        Task {
            gitBranch = await GitInfo.branch(cwd: cwd)
        }
    }

    private func handle(notification: HermesNotification) {
        switch notification {
        case let .sessionUpdate(notification):
            handle(sessionUpdate: notification.update)
        case let .permissionRequest(event):
            handle(permissionRequest: event)
        case let .clientRequestError(_, method, message):
            hasError = true
            statusText = "\(method) response failed: \(message)"
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

    private func handle(sessionUpdate update: SessionUpdate) {
        switch update {
        case let .userMessageChunk(chunk):
            appendStreaming(kind: .user, text: chunk.content.plainText ?? "", stream: .user)
        case let .agentMessageChunk(chunk):
            appendStreaming(kind: .agent, text: chunk.content.plainText ?? "", stream: .agent)
        case let .agentThoughtChunk(chunk):
            appendStreaming(kind: .thought, text: chunk.content.plainText ?? "", stream: .thought)
        case let .toolCall(toolCall):
            resetStreamingMessages()
            upsertToolMessage(
                id: toolCall.toolCallId,
                title: toolCall.title,
                status: toolCall.status,
                content: toolCall.content
            )
        case let .toolCallUpdate(update):
            resetStreamingMessages()
            upsertToolMessage(
                id: update.toolCallId,
                title: update.title,
                status: update.status,
                content: update.content
            )
        case let .availableCommandsUpdate(update):
            availableCommands = update.availableCommands
        default:
            if let text = update.displayText {
                resetStreamingMessages()
                append(kind: .event, text: text)
            }
        }
    }

    private func handle(permissionRequest event: PermissionRequestEvent) {
        resetStreamingMessages()
        upsertToolMessage(
            id: event.request.toolCall.toolCallId,
            title: event.request.toolCall.title,
            status: event.request.toolCall.status ?? .pending,
            content: event.request.toolCall.content
        )
        pendingPermission = PermissionPromptState(id: event.id, request: event.request) { outcome in
            await event.respond(outcome)
        }
        statusText = "Waiting for permission"
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

    private func upsertToolMessage(
        id toolCallId: ToolCallId,
        title: String?,
        status: ToolCallStatus?,
        content: [ToolCallContent]?
    ) {
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
            messages[index].toolTitle = displayTitle
            if let status {
                messages[index].toolStatus = status
            }
            if let content {
                messages[index].toolContent = content
            }
        } else {
            let message = ChatTranscriptMessage(
                kind: .tool,
                text: text,
                toolCallId: toolCallId,
                toolTitle: displayTitle,
                toolStatus: status,
                toolContent: content ?? []
            )
            messages.append(message)
            toolMessageIds[toolCallId] = message.id
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
