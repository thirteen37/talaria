import Foundation

/// Sidebar "Browse" destinations selectable in the desktop window's detail
/// column. Shared with the iPhone Browse sheet, which reads the same title/icon
/// metadata so both surfaces stay in sync.
enum BrowseDestination: String, Hashable {
    case sessions
    case extensions
    case cron
    case kanban
    case gateway
    case hermesProfiles
    case system
    case profiles
    case personalities
    case models

    /// Row title shown in the desktop sidebar and the iPhone Browse list.
    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .extensions: return "Skills, Tools, MCP, Plugins"
        case .cron: return "Cron"
        case .kanban: return "Kanban"
        case .gateway: return "Gateway & Messaging"
        case .hermesProfiles: return "Profiles"
        case .profiles: return "Config & Env"
        case .personalities: return "Soul, Personalities & Memory"
        case .models: return "Models"
        case .system: return "System"
        }
    }

    /// SF Symbol paired with `title` in each surface's row label.
    var systemImage: String {
        switch self {
        case .sessions: return "clock.arrow.circlepath"
        case .extensions: return "puzzlepiece.extension"
        case .cron: return "calendar"
        case .kanban: return "rectangle.split.3x1"
        case .gateway: return "antenna.radiowaves.left.and.right"
        case .hermesProfiles: return "square.stack.3d.up"
        case .profiles: return "slider.horizontal.3"
        case .personalities: return "theatermasks"
        case .models: return "cpu"
        case .system: return "gauge.medium"
        }
    }

    /// The "manage" destinations the iPhone Browse list offers, in desktop
    /// sidebar order. Excludes `.sessions`, which iPhone reaches via the chat
    /// stack and the All-Sessions toolbar button rather than Browse.
    static let manageOrder: [BrowseDestination] = [
        .extensions, .cron, .kanban, .gateway, .hermesProfiles, .profiles, .personalities, .models, .system,
    ]

    /// Full desktop-sidebar order (`.sessions` pinned first, then the manage
    /// pages). The View menu's no-focus fallback list, so its structure +
    /// shortcuts stay present even when no window is focused.
    static let sidebarOrder: [BrowseDestination] = [.sessions] + manageOrder
}
