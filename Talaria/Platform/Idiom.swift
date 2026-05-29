import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Runtime check rather than compile-time. iPad compiles the same iOS target
/// but should retain the full sidebar — only iPhone collapses to chats+sessions.
enum Idiom {
    @MainActor
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}
