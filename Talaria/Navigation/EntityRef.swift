import HermesKit

/// The single source of truth for "what is linkable, and where does it live".
///
/// Each case maps to the ``BrowseDestination`` page that manages the entity; for
/// tabbed pages the consumer also switches on the case to pick the right tab and
/// pre-select the matching row. ``session`` is special — it opens the chat via
/// `store.selection` rather than a browse page, so its ``destination`` is only a
/// placeholder and routers handle it before consulting that value.
enum EntityRef: Equatable {
    case modelMain
    case modelAuxiliary(task: String)
    case hermesProfile(name: String)
    case session(SessionId)
    case skill(id: String)
    case tool(name: String)
    case mcpServer(name: String)
    case plugin(name: String)
    case cronJob(id: String)
    case personality(name: String)
    case envVar(name: String)
    case kanbanBoard(slug: String)

    /// The browse page that manages this entity.
    ///
    /// ``session`` has no browse page — it opens the chat — so it falls back to
    /// `.sessions`; callers route session refs specially and never rely on this.
    var destination: BrowseDestination {
        switch self {
        case .modelMain, .modelAuxiliary: return .models
        case .hermesProfile: return .hermesProfiles
        case .skill, .tool, .mcpServer, .plugin: return .extensions
        case .cronJob: return .cron
        case .personality: return .personalities
        case .envVar: return .profiles
        case .kanbanBoard: return .kanban
        case .session: return .sessions
        }
    }

    /// The Models-page picker slot a model ref should focus, or nil for
    /// non-model refs. Lets the Models consumer reuse `ModelsHarness.beginPick`.
    var modelPickerTarget: ModelPickerTarget? {
        switch self {
        case .modelMain: return .main
        case let .modelAuxiliary(task): return .auxiliary(task: task)
        default: return nil
        }
    }

    /// The session id for a `.session` ref, or nil otherwise. Lets routers
    /// special-case "open the chat" before consulting ``destination``.
    var sessionId: SessionId? {
        if case let .session(id) = self { return id }
        return nil
    }
}
