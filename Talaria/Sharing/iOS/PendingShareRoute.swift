import Foundation

/// Identifies a share the iOS Share Extension staged into the App Group
/// container, awaiting host-app pickup via `talaria://share?id=<id>`. Modeled on
/// `NotificationRoute` — a tiny value the deep-link reactor carries. The `id` is
/// an opaque key into the App Group container; a forged/guessed `talaria://`
/// URL at worst resolves to "no item found" (see docs/security.md).
struct PendingShareRoute: Equatable, Sendable, Identifiable {
    let id: UUID
}

extension PendingShareRoute {
    /// Parses `talaria://share?id=<uuid>`, or nil if the URL isn't a share
    /// hand-off with a valid id.
    init?(url: URL) {
        guard url.scheme == "talaria", url.host == "share",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: idString)
        else { return nil }
        self.init(id: id)
    }
}
