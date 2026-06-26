import Foundation
import Testing
@testable import HermesKit

@Suite
struct HindsightBrowseErrorTests {
    @Test
    func connectionRefusedIsDaemonUnreachable() {
        #expect(HindsightBrowseError.classify(URLError(.cannotConnectToHost)) == .daemonUnreachable)
        #expect(HindsightBrowseError.classify(URLError(.cannotFindHost)) == .daemonUnreachable)
        #expect(HindsightBrowseError.classify(URLError(.networkConnectionLost)) == .daemonUnreachable)
        #expect(HindsightBrowseError.classify(URLError(.timedOut)) == .daemonUnreachable)
    }

    @Test
    func embeddedPortUnknownIsDaemonNotInitialized() {
        // Config is present (mode/profile read OK) but the daemon's port isn't in
        // metadata.json — distinct from "no config at all".
        let err = HindsightEndpointError.embeddedProfilePortUnknown(profile: "hermes")
        #expect(HindsightBrowseError.classify(err) == .daemonNotInitialized)
    }

    @Test
    func unsupportedModeIsNotConfigured() {
        #expect(HindsightBrowseError.classify(HindsightEndpointError.unsupportedMode("disabled")) == .notConfigured)
    }

    @Test
    func missingConfigFileIsNotConfigured() {
        let err = HermesFileStoreError.notFound(path: "hindsight/config.json")
        #expect(HindsightBrowseError.classify(err) == .notConfigured)
    }

    @Test
    func unauthorizedStatusMapsToUnauthorized() {
        #expect(HindsightBrowseError.classify(HindsightAPIError.http(statusCode: 401, body: "")) == .unauthorized)
        #expect(HindsightBrowseError.classify(HindsightAPIError.http(statusCode: 403, body: "")) == .unauthorized)
    }

    @Test
    func otherHTTPStatusPreservesCode() {
        #expect(HindsightBrowseError.classify(HindsightAPIError.http(statusCode: 500, body: "x")) == .http(statusCode: 500))
    }

    @Test
    func remoteEmbeddedMapsToRemoteUnsupported() {
        let err = HindsightEndpointError.remoteEmbeddedUnsupported
        #expect(HindsightBrowseError.classify(err) == .remoteEmbeddedUnsupported)
    }

    @Test
    func everyCaseHasGuidanceText() {
        let cases: [HindsightBrowseError] = [
            .daemonUnreachable, .notConfigured, .daemonNotInitialized, .unauthorized,
            .http(statusCode: 500), .remoteEmbeddedUnsupported, .other("boom"),
        ]
        for c in cases {
            #expect(!c.guidance.isEmpty)
        }
    }
}
