import Foundation

public enum HermesHomePaths {
    /// Builds a path beneath the configured Hermes home that can be handed to a
    /// remote file transfer. SFTP and `cat` fetches do not expand `~` or `$HOME`,
    /// so those forms are stripped to paths relative to the login user's home.
    public static func relativePath(hermesHome: String?, tail: String) -> String {
        guard let raw = hermesHome?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return ".hermes/\(tail)"
        }
        for prefix in ["~", "$HOME", "${HOME}"] {
            if raw == prefix {
                return tail
            }
            if raw.hasPrefix(prefix + "/") {
                let stripped = String(raw.dropFirst(prefix.count + 1)).trimmingTrailingSlashes()
                return stripped.isEmpty ? tail : "\(stripped)/\(tail)"
            }
        }
        return "\(raw.trimmingTrailingSlashes())/\(tail)"
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var value = self
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
