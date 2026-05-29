import HermesKit
import SwiftUI

struct ChatView: View {
    // The view model is owned by SessionsStore (keyed by sessionId) so it
    // survives view destruction — switching tabs no longer cancels the
    // in-flight prompt or loses the transcript.
    @Bindable var viewModel: LocalChatViewModel

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
                gitBranch: viewModel.gitBranch,
                contextUsed: viewModel.contextUsed,
                contextSize: viewModel.contextSize
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
        // Inline title (iOS) keeps the chat's vertical space for the transcript
        // instead of the tall large-title header; no-op on macOS.
        .inlineNavigationTitle()
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
    var contextUsed: Int?
    var contextSize: Int?

    private weak var manager: SessionManager?
    private weak var store: SessionsStore?
    private let sessionId: SessionId
    private let cwd: String
    private var notificationTask: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?
    private var currentUserStreamMessageId: UUID?
    private var currentAgentMessageId: UUID?
    private var currentThoughtMessageId: UUID?
    private var toolMessageIds: [ToolCallId: UUID] = [:]
    private var toolTitles: [ToolCallId: String] = [:]

    init(manager: SessionManager, sessionId: SessionId, cwd: String, store: SessionsStore? = nil) {
        self.manager = manager
        self.sessionId = sessionId
        self.cwd = cwd
        self.store = store
    }

    func start() async {
        guard notificationTask == nil, let manager else {
            return
        }
        statusText = "Session cwd: \(cwd)"
        loadGitBranch()

        let stream = await manager.notifications(for: sessionId)
        notificationTask = Task { [weak self] in
            for await notification in stream {
                await self?.handle(notification: notification)
            }
        }
    }

    func sendPrompt() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, pendingPermission == nil else {
            return
        }
        guard let manager, let client = await manager.client(for: sessionId) else {
            hasError = true
            statusText = "Session is not active"
            return
        }

        prompt = ""
        _ = append(kind: .user, text: text)
        resetStreamingMessages()
        currentUserStreamMessageId = messages.last?.id
        isSending = true
        turnStartDate = Date()
        statusText = "Hermes is working in \(cwd)..."
        hasError = false
        store?.markTurnStarted(id: sessionId)

        let id = sessionId
        promptTask = Task { [weak self] in
            do {
                let response = try await client.prompt(sessionId: id, content: text)
                self?.statusText = "Stopped: \(response.stopReason.rawValue)"
            } catch is CancellationError {
                self?.statusText = "Cancelled"
            } catch {
                self?.hasError = true
                self?.statusText = self?.errorMessage(for: error)
            }
            self?.isSending = false
            self?.turnStartDate = nil
            self?.store?.markTurnFinished(id: id)
        }
    }

    func cancel() async {
        promptTask?.cancel()

        if pendingPermission != nil {
            await resolvePermission(.cancelled)
        }

        guard let manager, let client = await manager.client(for: sessionId) else {
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
        notificationTask = nil
        promptTask?.cancel()
        if pendingPermission != nil {
            await resolvePermission(.cancelled)
        }
        isSending = false
        turnStartDate = nil
        resetStreamingMessages()
    }

    private func loadGitBranch() {
        let cwd = cwd
        Task {
            gitBranch = await GitInfo.branch(cwd: cwd)
        }
    }

    private func handle(notification: HermesNotification) async {
        switch notification {
        case let .sessionUpdate(notification):
            guard notification.sessionId == sessionId else {
                return
            }
            handle(sessionUpdate: notification.update)
        case let .permissionRequest(event):
            guard event.request.sessionId == sessionId else {
                return
            }
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
            if let client = await manager?.client(for: sessionId) {
                try? await client.respond(
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
        case let .usageUpdate(update):
            contextUsed = update.used
            contextSize = update.size
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
