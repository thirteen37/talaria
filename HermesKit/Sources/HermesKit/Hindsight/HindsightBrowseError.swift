import Foundation

/// A user-facing classification of failures hit while browsing Hindsight, with
/// guidance copy. Keeps the view layer free of transport/decoding internals.
public enum HindsightBrowseError: Equatable, Sendable {
    /// The (local) daemon couldn't be reached — usually it isn't running (it
    /// idle-stops after a few minutes) or the host is unreachable.
    case daemonUnreachable
    /// Hindsight isn't configured for this profile (no `hindsight/config.json`),
    /// or the mode isn't browsable.
    case notConfigured
    /// Hindsight *is* configured (embedded), but its daemon's port isn't in
    /// `metadata.json` — the embedded daemon for this profile has never run.
    case daemonNotInitialized
    /// The API rejected the request's credentials (cloud / local_external).
    case unauthorized
    /// Any other non-2xx HTTP status.
    case http(statusCode: Int)
    /// The profile is remote and Hindsight runs as a local-embedded daemon on the
    /// remote host — not reachable from here in v1 (needs an SSH tunnel).
    case remoteEmbeddedUnsupported
    /// Anything else (decoding, unexpected transport errors).
    case other(String)

    /// Short guidance shown beneath the headline in the error state.
    public var guidance: String {
        switch self {
        case .daemonUnreachable:
            return "The Hindsight daemon isn't reachable. It stops after a few minutes idle — run a Hermes chat (or start the daemon) and try again."
        case .notConfigured:
            return "Hindsight doesn't appear to be set up for this profile yet. Configure it in Hermes (memory setup) and retain a memory first."
        case .daemonNotInitialized:
            return "Hindsight is configured, but its memory daemon hasn't started for this profile yet. Run a Hermes chat (or start the daemon) to initialize it, then retry."
        case .unauthorized:
            return "Hindsight rejected the request. Check the HINDSIGHT_API_KEY for this profile."
        case .http(let statusCode):
            return "Hindsight returned HTTP \(statusCode). Try again, or check the daemon logs."
        case .remoteEmbeddedUnsupported:
            return "Couldn't open a tunnel to the remote Hindsight daemon. Make sure the connection to this profile is up, then retry."
        case .other(let detail):
            return detail
        }
    }

    /// Map a raw error into a browse-facing category.
    public static func classify(_ error: Error) -> HindsightBrowseError {
        switch error {
        case let endpoint as HindsightEndpointError:
            switch endpoint {
            case .embeddedProfilePortUnknown:
                return .daemonNotInitialized
            case .unsupportedMode:
                return .notConfigured
            case .remoteEmbeddedUnsupported:
                return .remoteEmbeddedUnsupported
            case .invalidBaseURL(let url):
                return .other("Invalid Hindsight URL: \(url)")
            }
        case let store as HermesFileStoreError:
            if case .notFound = store { return .notConfigured }
            return .other(store.localizedDescription)
        case let api as HindsightAPIError:
            switch api {
            case .http(let statusCode, _):
                return (statusCode == 401 || statusCode == 403) ? .unauthorized : .http(statusCode: statusCode)
            case .decoding(let detail):
                return .other("Couldn't read Hindsight's response: \(detail)")
            case .nonHTTPResponse:
                return .daemonUnreachable
            }
        case let url as URLError:
            switch url.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .timedOut, .notConnectedToInternet, .dnsLookupFailed:
                return .daemonUnreachable
            default:
                return .other(url.localizedDescription)
            }
        default:
            return .other(error.localizedDescription)
        }
    }
}
