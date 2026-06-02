import Foundation

/// One entry from the Skills Hub index — the fields the native search UI needs.
/// The index also carries `repo`, `path`, and `extra`, which `JSONDecoder`
/// ignores since they aren't modeled here.
public struct HubCatalogSkill: Codable, Equatable, Sendable, Identifiable {
    public let name: String
    public let description: String
    /// `official` | `github` | `clawhub` | `lobehub` | `skills-sh` | …
    public let source: String
    /// Install identifier, e.g. `official/security/1password`. Stable + unique,
    /// so it doubles as `id`.
    public let identifier: String
    /// `builtin` | `trusted` | `community` (maps `trust_level`).
    public let trustLevel: String
    public let tags: [String]

    public var id: String { identifier }

    enum CodingKeys: String, CodingKey {
        case name, description, source, identifier, tags
        case trustLevel = "trust_level"
    }

    public init(
        name: String,
        description: String,
        source: String,
        identifier: String,
        trustLevel: String,
        tags: [String] = []
    ) {
        self.name = name
        self.description = description
        self.source = source
        self.identifier = identifier
        self.trustLevel = trustLevel
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        // Be lenient on the metadata fields so a leaner-than-expected entry in
        // the ~88k-row index can't fail the whole decode.
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
        identifier = (try? c.decode(String.self, forKey: .identifier)) ?? name
        trustLevel = (try? c.decode(String.self, forKey: .trustLevel)) ?? ""
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
    }
}

public enum SkillsHubCatalogError: Error, Equatable, Sendable, LocalizedError {
    /// Network/HTTP failed and there was no cached copy to fall back on.
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "Couldn't load the Skills Hub catalog: \(detail)"
        }
    }
}

/// Read-only HTTP client for the Skills Hub **search** index. Fetches the
/// canonical Nous index once (conditional GET via `ETag`), caches the decoded
/// array on disk with a TTL, and filters client-side. Plain public HTTP — no
/// auth, no Hermes process, works on iOS — so search is available even when the
/// admin runner (which backs install/update/uninstall) isn't.
///
/// An `actor` so the in-memory cache and the disk-load-once flag are serialized
/// without a lock; decoding the ~7 MB (gzip) / ~34 MB (raw) payload happens on
/// the actor's executor, off the main thread.
///
/// > Note: An alternative search endpoint exists — `https://skills.sh/api/search?q=`
/// > offers light server-side fuzzy matching but **no descriptions**. The Nous
/// > index is the single official source that ships full descriptions + tags, so
/// > this client uses it and filters locally.
public actor SkillsHubCatalog {
    /// Canonical Nous index. Hermes itself caches this (6h TTL) —
    /// `tools/skills_hub.py` `HERMES_INDEX_URL`.
    public static let defaultIndexURL = URL(
        string: "https://hermes-agent.nousresearch.com/docs/api/skills-index.json"
    )!

    private let indexURL: URL
    private let cacheURL: URL?
    private let ttl: TimeInterval
    private let http: any DashboardHTTP
    private let now: @Sendable () -> Date
    private let maxResults: Int

    private var memory: Cached?
    private var loadedFromDisk = false

    private struct Cached: Codable {
        var etag: String?
        var fetchedAt: Date
        var skills: [HubCatalogSkill]
    }

    public init(
        indexURL: URL = SkillsHubCatalog.defaultIndexURL,
        cacheURL: URL? = SkillsHubCatalog.defaultCacheURL(),
        ttl: TimeInterval = 6 * 3600,
        maxResults: Int = 50,
        http: any DashboardHTTP = URLSession.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.indexURL = indexURL
        self.cacheURL = cacheURL
        self.ttl = ttl
        self.maxResults = maxResults
        self.http = http
        self.now = now
    }

    /// Default on-disk cache location under Application Support. Returns nil only
    /// if the directory can't be resolved (extremely unusual), in which case the
    /// catalog runs memory-only.
    public static func defaultCacheURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base
            .appendingPathComponent("HermesKit", isDirectory: true)
            .appendingPathComponent("skills-hub-index.json", isDirectory: false)
    }

    /// Returns the catalog, fetching/refreshing as needed:
    /// - serves the in-memory/disk cache while it's within the TTL;
    /// - otherwise issues a conditional GET (`If-None-Match`) — 304 revalidates
    ///   the cache, 200 replaces it;
    /// - on any network/HTTP failure, serves a stale cache if one exists
    ///   (`stale-while-revalidate`), else throws `.unavailable`.
    @discardableResult
    public func skills() async throws -> [HubCatalogSkill] {
        loadFromDiskIfNeeded()

        if let memory, now().timeIntervalSince(memory.fetchedAt) < ttl {
            return memory.skills
        }

        do {
            return try await revalidate()
        } catch {
            if let memory { return memory.skills }   // stale-while-revalidate
            throw SkillsHubCatalogError.unavailable(error.localizedDescription)
        }
    }

    /// Case-insensitive ranked filter over the last-loaded catalog. Call
    /// ``skills()`` first to populate it. Ranking: name-prefix beats
    /// name-substring beats description/tag match; capped at `maxResults`.
    public func search(_ query: String) -> [HubCatalogSkill] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, let skills = memory?.skills else { return [] }

        var ranked: [(rank: Int, index: Int, skill: HubCatalogSkill)] = []
        for (index, skill) in skills.enumerated() {
            let name = skill.name.lowercased()
            let rank: Int
            if name.hasPrefix(trimmed) {
                rank = 0
            } else if name.contains(trimmed) {
                rank = 1
            } else if skill.description.lowercased().contains(trimmed)
                || skill.tags.contains(where: { $0.lowercased().contains(trimmed) }) {
                rank = 2
            } else {
                continue
            }
            ranked.append((rank, index, skill))
        }
        // Stable: equal ranks keep the index's catalog order.
        ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
        return ranked.prefix(maxResults).map(\.skill)
    }

    // MARK: - Fetch

    private func revalidate() async throws -> [HubCatalogSkill] {
        var request = URLRequest(url: indexURL)
        request.httpMethod = "GET"
        // We manage freshness explicitly; don't let URLSession's own cache
        // short-circuit the conditional GET.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = memory?.etag, memory?.skills.isEmpty == false {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await http.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let status = httpResponse?.statusCode ?? 200

        if status == 304, let memory {
            // Unchanged upstream — bump freshness and reuse the cached array.
            let revalidated = Cached(etag: memory.etag, fetchedAt: now(), skills: memory.skills)
            self.memory = revalidated
            persist(revalidated)
            return revalidated.skills
        }

        guard (200..<300).contains(status) else {
            throw SkillsHubCatalogError.unavailable("HTTP \(status)")
        }

        let index = try JSONDecoder().decode(IndexEnvelope.self, from: data)
        let etag = httpResponse?.value(forHTTPHeaderField: "ETag")
        let fresh = Cached(etag: etag, fetchedAt: now(), skills: index.skills)
        self.memory = fresh
        persist(fresh)
        return fresh.skills
    }

    private struct IndexEnvelope: Decodable {
        let skills: [HubCatalogSkill]
    }

    // MARK: - Disk cache

    private func loadFromDiskIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return }
        if let decoded = try? JSONDecoder().decode(Cached.self, from: data) {
            memory = decoded
        }
    }

    private func persist(_ cached: Cached) {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(cached)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Best-effort cache; a write failure just means the next launch
            // re-fetches. Don't surface it.
        }
    }
}
