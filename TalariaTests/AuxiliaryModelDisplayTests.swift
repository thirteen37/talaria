import Foundation
import HermesKit
import Testing
@testable import Talaria

@Suite
struct AuxiliaryModelDisplayTests {
    private func slot(
        task: String = "title_generation",
        provider: String?,
        model: String?,
        baseURL: String?
    ) -> DashboardAuxiliaryModel {
        // Decode through JSON so we exercise the real Codable init the dashboard
        // uses — there's no public memberwise initializer.
        let json = """
        {"task":\(quote(task)),"provider":\(quote(provider)),"model":\(quote(model)),"base_url":\(quote(baseURL))}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(DashboardAuxiliaryModel.self, from: Data(json.utf8))
    }

    private func quote(_ value: String?) -> String {
        guard let value else { return "null" }
        return "\"\(value)\""
    }

    @Test
    func customSlotShowsProviderAndModel() {
        let row = slot(provider: "binky-litellm", model: "fast", baseURL: "")
        #expect(AuxiliaryModelDisplay.subtitle(for: row) == "binky-litellm · fast")
    }

    @Test
    func baseURLIsIgnoredAndNeverShown() {
        // base_url is a decoupled, often-stale override — it must not leak into
        // the row (it read as if it were the provider's address).
        let row = slot(provider: "binky-litellm", model: "fast", baseURL: "http://grendahl.local:49437/v1")
        #expect(AuxiliaryModelDisplay.subtitle(for: row) == "binky-litellm · fast")
    }

    @Test
    func autoSlotRendersAutoLabelRegardlessOfBaseURL() {
        // provider:"auto" + empty model ⇒ inherits the main model; a stray
        // base_url must not turn it into a custom-looking row.
        let row = slot(provider: "auto", model: "", baseURL: "http://grendahl.local:49437/v1")
        #expect(AuxiliaryModelDisplay.subtitle(for: row) == "auto (use main model)")
    }

    @Test
    func emptyProviderSlotRendersAutoLabel() {
        let row = slot(provider: "", model: "", baseURL: "")
        #expect(AuxiliaryModelDisplay.subtitle(for: row) == "auto (use main model)")
    }

    @Test
    func providerOnlyWhenModelMissing() {
        let row = slot(provider: "openrouter", model: "", baseURL: "")
        #expect(AuxiliaryModelDisplay.subtitle(for: row) == "openrouter")
    }
}
