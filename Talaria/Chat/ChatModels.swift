import HermesKit
import SwiftUI

struct ChatTranscriptMessage: Identifiable, Equatable {
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
    var toolTitle: String?
    var toolStatus: ToolCallStatus?
    var toolContent: [ToolCallContent]

    init(
        kind: Kind,
        text: String,
        toolCallId: ToolCallId? = nil,
        toolTitle: String? = nil,
        toolStatus: ToolCallStatus? = nil,
        toolContent: [ToolCallContent] = []
    ) {
        self.kind = kind
        self.text = text
        self.toolCallId = toolCallId
        self.toolTitle = toolTitle
        self.toolStatus = toolStatus
        self.toolContent = toolContent
    }
}

extension ToolCallStatus {
    /// Active states keep the tool card expanded; terminal states collapse it.
    var isActive: Bool {
        self == .pending || self == .inProgress
    }
}

extension Optional where Wrapped == ToolCallStatus {
    /// A `nil` status (e.g. an allowed-and-cleared permission) is treated as terminal.
    var isActive: Bool {
        self?.isActive ?? false
    }
}

struct PermissionPromptState: Identifiable {
    let id: JSONRPCID
    var request: RequestPermissionRequest
    var respond: (PermissionOutcome) async -> Void
}

enum StreamKind {
    case user
    case agent
    case thought
}
