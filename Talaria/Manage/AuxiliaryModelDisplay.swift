import HermesKit

/// Formats an auxiliary model slot's subtitle for the Models screen.
///
/// Pulled out of the SwiftUI view so the formatting rules are unit-testable
/// without standing up a view.
///
/// Deliberately ignores `base_url`. That field is *not* the slot provider's
/// endpoint — it's a separate `auxiliary.<task>.base_url` override that
/// `GET /api/model/auxiliary` echoes verbatim, is usually empty, and goes stale
/// because `POST /api/model/set` only writes `provider`/`model`. Folding it into
/// the provider label read as "provider X lives at host Y", which was wrong and
/// confusing. The `provider` string already identifies the slot (including the
/// `custom:<name>` form), so that's all we show. Talaria now *clears* a stale
/// `base_url` when a slot's provider changes — see `AuxiliaryModelConfig`.
enum AuxiliaryModelDisplay {
    /// The slot's subtitle string.
    ///
    /// - `auto`/unset slots → `"auto (use main model)"`.
    /// - Otherwise `"provider · model"` (or a bare `provider`/`model` when only
    ///   one is present).
    static func subtitle(for slot: DashboardAuxiliaryModel) -> String {
        if slot.isAuto { return "auto (use main model)" }
        let model = slot.model ?? ""
        let provider = slot.provider ?? ""
        if model.isEmpty {
            return provider.isEmpty ? "auto (use main model)" : provider
        }
        return provider.isEmpty ? model : "\(provider) · \(model)"
    }
}
