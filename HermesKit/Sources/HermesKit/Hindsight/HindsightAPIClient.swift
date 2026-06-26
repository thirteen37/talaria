import Foundation

/// Errors surfaced by ``HindsightAPIClient``.
///
/// The Hindsight REST API is an *external* surface (the same FastAPI server backs
/// Hindsight Cloud and the local-embedded daemon), so failures are reported as a
/// small, explicit set rather than leaking `URLError`/decoding internals.
public enum HindsightAPIError: Error, Equatable, Sendable {
    /// A non-2xx HTTP response. `body` is a best-effort UTF-8 snippet for diagnostics.
    case http(statusCode: Int, body: String)
    /// The response body could not be decoded into the expected shape.
    case decoding(String)
    /// The response was not an HTTP response (unexpected transport behaviour).
    case nonHTTPResponse
}

/// A single memory unit as returned by Hindsight's `memories/list` and `memories/recall`.
///
/// The two endpoints return *overlapping but not identical* JSON: a listed item uses
/// `text` + `date` and a formatted `entities` **string**, while a recall result uses
/// `text` + `mentioned_at` and an `entities` **list**. Decoding is deliberately tolerant
/// (optional fields, either-shape `entities`, multiple timestamp keys) because the shape
/// is owned by an external service.
public struct HindsightMemory: Identifiable, Equatable, Sendable {
    public let id: String
    /// The memory's content (`text`, falling back to `content`).
    public let text: String
    /// Raw timestamp string (`date`/`timestamp`/`mentioned_at`/`created_at`/`occurred_start`), if any.
    public let timestamp: String?
    public let context: String?
    /// Entity labels, normalised to a list whether the source was a list or a formatted string.
    public let entities: [String]
    public let tags: [String]
    public let type: String?
    public let metadata: [String: String]
    public let documentID: String?

    public init(
        id: String,
        text: String,
        timestamp: String? = nil,
        context: String? = nil,
        entities: [String] = [],
        tags: [String] = [],
        type: String? = nil,
        metadata: [String: String] = [:],
        documentID: String? = nil
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.context = context
        self.entities = entities
        self.tags = tags
        self.type = type
        self.metadata = metadata
        self.documentID = documentID
    }

    /// The timestamp parsed as a `Date`, tolerating ISO-8601 with or without fractional seconds.
    public var date: Date? { timestamp.flatMap(HindsightMemory.parseDate) }

    static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

extension HindsightMemory: Decodable {
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ s: String) { self.stringValue = s }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)

        func string(_ key: String) -> String? {
            guard let k = DynamicKey(stringValue: key) else { return nil }
            return try? c.decode(String.self, forKey: k)
        }

        let resolvedID = string("id") ?? UUID().uuidString
        let resolvedText = string("text") ?? string("content") ?? ""
        let resolvedTimestamp = ["date", "timestamp", "mentioned_at", "created_at", "occurred_start"]
            .lazy.compactMap { string($0) }.first

        // entities: either ["Alice", "Google"] or "Alice (PERSON), Google (ORGANIZATION)"
        var resolvedEntities: [String] = []
        if let k = DynamicKey(stringValue: "entities") {
            if let list = try? c.decode([String].self, forKey: k) {
                resolvedEntities = list
            } else if let joined = try? c.decode(String.self, forKey: k) {
                resolvedEntities = joined
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }

        var resolvedTags: [String] = []
        if let k = DynamicKey(stringValue: "tags"), let list = try? c.decode([String].self, forKey: k) {
            resolvedTags = list
        }

        var resolvedMetadata: [String: String] = [:]
        if let k = DynamicKey(stringValue: "metadata"), let map = try? c.decode([String: String].self, forKey: k) {
            resolvedMetadata = map
        }

        self.init(
            id: resolvedID,
            text: resolvedText,
            timestamp: resolvedTimestamp,
            context: string("context"),
            entities: resolvedEntities,
            tags: resolvedTags,
            type: string("type"),
            metadata: resolvedMetadata,
            documentID: string("document_id")
        )
    }
}

/// One page of `memories/list` results (`{ items, total, limit, offset }`), newest-first.
public struct HindsightMemoryPage: Decodable, Equatable, Sendable {
    public let items: [HindsightMemory]
    public let total: Int
    public let limit: Int
    public let offset: Int

    public init(items: [HindsightMemory], total: Int, limit: Int, offset: Int) {
        self.items = items
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}

/// Read-only HTTP client for Hindsight's memory-browse surface.
///
/// Talks the same `/v1/{tenant}/banks/{bank}/…` REST API exposed by Hindsight Cloud and
/// the local-embedded `hindsight-api` daemon. `apiKey` is sent as a bearer token for
/// cloud / local_external; for the localhost embedded daemon it is `nil` (no auth).
public struct HindsightAPIClient: Sendable {
    private let baseURL: URL
    private let apiKey: String?
    private let tenant: String
    private let http: any DashboardHTTP

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        tenant: String = "default",
        http: any DashboardHTTP = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tenant = tenant
        self.http = http
    }

    /// `GET /v1/{tenant}/banks/{bank}/memories/list` — paginated, most-recent-first.
    /// `query` maps to the API's `q` full-text filter; omitted when nil/empty.
    public func listMemories(
        bank: String,
        query: String? = nil,
        type: String? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> HindsightMemoryPage {
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: query))
        }
        if let type, !type.isEmpty {
            queryItems.append(URLQueryItem(name: "type", value: type))
        }
        let request = makeRequest(
            method: "GET",
            path: "/v1/\(tenant)/banks/\(bank)/memories/list",
            queryItems: queryItems
        )
        return try await send(request)
    }

    /// `POST /v1/{tenant}/banks/{bank}/memories/recall` — multi-strategy semantic search.
    public func recall(
        bank: String,
        query: String,
        types: [String]? = nil
    ) async throws -> [HindsightMemory] {
        var payload: [String: Any] = ["query": query]
        if let types, !types.isEmpty { payload["types"] = types }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = makeRequest(
            method: "POST",
            path: "/v1/\(tenant)/banks/\(bank)/memories/recall",
            body: body
        )
        let response: RecallResponse = try await send(request)
        return response.results
    }

    private struct RecallResponse: Decodable {
        let results: [HindsightMemory]
    }

    // MARK: - Transport

    private func makeRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await http.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HindsightAPIError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HindsightAPIError.http(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HindsightAPIError.decoding(String(describing: error))
        }
    }
}
