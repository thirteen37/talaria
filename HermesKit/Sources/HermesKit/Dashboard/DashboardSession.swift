import Foundation

public enum DashboardSessionError: Error, Equatable, Sendable, LocalizedError {
    /// `GET /` succeeded but the response HTML didn't carry the
    /// `window.__HERMES_SESSION_TOKEN__` boot block. Indicates a Hermes
    /// release that changed the SPA shape — gate the per-route capability
    /// flag off until upstream provides a token API.
    case tokenNotFoundInIndex
    case indexFailed(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .tokenNotFoundInIndex:
            return "Dashboard index didn't include a session token."
        case let .indexFailed(code):
            return "Dashboard index request failed (HTTP \(code))."
        }
    }
}

/// Owns the cached `X-Hermes-Session-Token` for one dashboard endpoint.
///
/// Hermes regenerates the token per process and only exposes it through the
/// SPA boot script, so the only way to acquire it programmatically is to
/// `GET /` and regex out the value. This object caches the scraped token,
/// re-acquires on 401, and hands out `DashboardClient`s wired with retry
/// semantics so callers don't have to thread the token through manually.
public final class DashboardSession: Sendable {
    public let baseURL: URL
    private let http: any DashboardHTTP
    private let tokenBox: TokenSnapshotBox

    public init(baseURL: URL, http: any DashboardHTTP = URLSession.shared) {
        self.baseURL = baseURL
        self.http = http
        self.tokenBox = TokenSnapshotBox()
    }

    public func tokenSnapshot() -> String? { tokenBox.value }

    public func invalidate() { tokenBox.value = nil }

    @discardableResult
    public func refresh() async throws -> String {
        let request = URLRequest(url: baseURL.appendingPathComponent("/"))
        let (data, response) = try await http.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DashboardSessionError.indexFailed(statusCode: http.statusCode)
        }
        let html = String(decoding: data, as: UTF8.self)
        guard let token = DashboardTokenExtractor.extract(fromHTML: html) else {
            throw DashboardSessionError.tokenNotFoundInIndex
        }
        tokenBox.value = token
        return token
    }

    /// Returns a `DashboardClient` whose `onUnauthorized` callback drops this
    /// session's cached token and re-scrapes it from `GET /`. The token
    /// closure reads the latest cached value, so the client's built-in
    /// retry automatically picks up the refreshed token without needing a
    /// second client instance.
    public func client() -> DashboardClient {
        DashboardClient(
            baseURL: baseURL,
            token: { [tokenBox] in tokenBox.value },
            onUnauthorized: { [weak self] in
                guard let self else { return }
                self.invalidate()
                _ = try? await self.refresh()
            },
            http: http
        )
    }
}

/// Synchronizes reads/writes to the cached session token from both the
/// `Sendable` token closure handed to `DashboardClient` and the async
/// `refresh()`/`invalidate()` methods on the session itself.
final class TokenSnapshotBox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DashboardSession.TokenSnapshot")
    private var _value: String?

    var value: String? {
        get { queue.sync { _value } }
        set { queue.sync { _value = newValue } }
    }
}
