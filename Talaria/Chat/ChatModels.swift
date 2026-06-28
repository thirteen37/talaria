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
    /// Normalized image bytes echoed in a user bubble (the images sent with this
    /// turn). Empty for every non-user message. Stored as already-normalized PNG/
    /// JPEG data so the bubble's thumbnails reuse the exact bytes sent on the wire.
    var images: [Data]
    var toolCallId: ToolCallId?
    var toolTitle: String?
    var toolStatus: ToolCallStatus?
    var toolContent: [ToolCallContent]

    init(
        kind: Kind,
        text: String,
        images: [Data] = [],
        toolCallId: ToolCallId? = nil,
        toolTitle: String? = nil,
        toolStatus: ToolCallStatus? = nil,
        toolContent: [ToolCallContent] = []
    ) {
        self.kind = kind
        self.text = text
        self.images = images
        self.toolCallId = toolCallId
        self.toolTitle = toolTitle
        self.toolStatus = toolStatus
        self.toolContent = toolContent
    }

    /// Custom equality that compares everything **except** the raw `images` bytes
    /// (only their count). `messages` is diffed with `==` on every mutation —
    /// including each streamed token via `.onChange(of:)` — and a user turn's
    /// images can be ~25 MB each; the synthesized `==` would memcmp those
    /// unchanged, immutable bytes on the main thread every token. Images never
    /// change after `append`, so excluding their contents is safe (mirrors why
    /// `ComposerAttachment` keys equality on `id`).
    static func == (lhs: ChatTranscriptMessage, rhs: ChatTranscriptMessage) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.text == rhs.text
            && lhs.toolCallId == rhs.toolCallId
            && lhs.toolTitle == rhs.toolTitle
            && lhs.toolStatus == rhs.toolStatus
            && lhs.toolContent == rhs.toolContent
            && lhs.images.count == rhs.images.count
    }

    /// A real user turn that "Undo back to here" can rewind to. Excludes locally
    /// echoed slash commands: `sendPrompt` echoes any `/`-prefixed composer input
    /// as a `.user` bubble but runs it through the harness instead of the LLM, so
    /// it has no matching Hermes turn. Counting those would inflate `/undo <N>`,
    /// and a slash echo shouldn't carry an Undo button. (A genuine user turn can
    /// never start with `/` — `sendPrompt` always routes that to the slash path.)
    var isUndoableUserTurn: Bool {
        kind == .user && !text.hasPrefix("/")
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
    var kind: UserPromptKind = .permission
    var respond: (PermissionOutcome) async -> Void
}

enum StreamKind {
    case user
    case agent
    case thought
}
