import Foundation

/// App version and build metadata for display in the UI.
///
/// `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` are static across local builds,
/// so they can't tell you whether a freshly compiled binary actually deployed.
/// In DEBUG, `builtAt` reads the executable's modification date — which changes
/// on every local build — giving a "is this the build I just made?" signal.
enum AppBuildInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// Modification date of the main executable — a build-time proxy for local
    /// builds only. Nil outside DEBUG: install/notarise/re-sign on shipped builds
    /// (TestFlight, App Store) reset the mtime to install time, which would make
    /// a "built …" label inaccurate.
    static var builtAt: Date? {
        #if DEBUG
        guard let url = Bundle.main.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date
        else { return nil }
        return date
        #else
        return nil
        #endif
    }

    /// `Talaria 1.0 (1)` in release; appends `· built 2026-05-31 15:42` in DEBUG.
    static var summary: String {
        let base = "Talaria \(version) (\(build))"
        guard let builtAt else { return base }
        let formatter = DateFormatter()
        // Pin the locale so the fixed format isn't reinterpreted against a
        // non-Gregorian device calendar (e.g. Buddhist → year 2569).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(base) · built \(formatter.string(from: builtAt))"
    }
}
