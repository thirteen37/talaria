import Foundation

/// Sidebar "Browse" destinations selectable in the desktop window's detail
/// column (and deep-linked from the notifications page).
enum BrowseDestination: Hashable {
    case sessions
    case skills
    case tools
    case cron
    case logs
    case doctor
    case updates
    case notifications
    case profiles
}
