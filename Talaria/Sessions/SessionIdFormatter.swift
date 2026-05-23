import Foundation
import HermesKit

enum SessionIdFormatter {
    // Pick the meaningful unique part of a session id. Hermes emits two shapes:
    // - CLI sessions: "YYYYMMDD_HHMMSS_<hex>" — show the trailing hex, the date
    //   prefix duplicates across rows.
    // - ACP sessions: UUIDs — show the leading group.
    static func short(_ id: SessionId) -> String {
        guard id.count > 8 else {
            return id
        }
        if let lastUnderscore = id.lastIndex(of: "_") {
            let suffix = String(id[id.index(after: lastUnderscore)...])
            if !suffix.isEmpty {
                return suffix
            }
        }
        if let firstHyphen = id.firstIndex(of: "-") {
            return String(id[..<firstHyphen])
        }
        return String(id.prefix(8))
    }
}
