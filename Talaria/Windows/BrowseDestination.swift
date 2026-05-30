import Foundation

/// Sidebar "Browse" destinations selectable in the desktop window's detail
/// column (and deep-linked from the notifications page). Shared with the iPhone
/// Browse sheet, which reads the same title/icon metadata so both surfaces stay
/// in sync.
enum BrowseDestination: Hashable {
    case sessions
    case skills
    case tools
    case cron
    case hermesProfiles
    case logs
    case doctor
    case updates
    case notifications
    case profiles
    case soul

    /// Row title shown in the desktop sidebar and the iPhone Browse list.
    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .skills: return "Skills"
        case .tools: return "Tools"
        case .cron: return "Cron"
        case .hermesProfiles: return "Profiles"
        case .profiles: return "Configuration"
        case .soul: return "Soul"
        case .logs: return "Logs"
        case .doctor: return "Doctor"
        case .updates: return "Updates"
        case .notifications: return "Notifications"
        }
    }

    /// SF Symbol paired with `title` in each surface's row label.
    var systemImage: String {
        switch self {
        case .sessions: return "clock.arrow.circlepath"
        case .skills: return "sparkles"
        case .tools: return "wrench.and.screwdriver"
        case .cron: return "calendar"
        case .hermesProfiles: return "square.stack.3d.up"
        case .profiles: return "slider.horizontal.3"
        case .soul: return "heart.text.square"
        case .logs: return "doc.text"
        case .doctor: return "stethoscope"
        case .updates: return "arrow.down.circle"
        case .notifications: return "bell"
        }
    }

    /// The "manage" destinations the iPhone Browse list offers, in desktop
    /// sidebar order. Excludes `.sessions`, which iPhone reaches via the chat
    /// stack and the All-Sessions toolbar button rather than Browse.
    static let manageOrder: [BrowseDestination] = [
        .skills, .tools, .cron, .hermesProfiles, .profiles, .soul, .logs, .doctor, .updates, .notifications,
    ]
}
