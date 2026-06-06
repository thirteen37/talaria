/// Pure transforms over the dashboard config's `auxiliary.<task>` mappings.
///
/// Hermes stores each auxiliary slot as `auxiliary.<task>.{provider, model,
/// base_url}` in `config.yaml`, and `GET /api/model/auxiliary` echoes those
/// fields verbatim. `POST /api/model/set` only writes `provider`/`model`, so a
/// `base_url` set earlier (e.g. by `hermes model`, which writes a custom
/// provider's URL alongside it) lingers after a dashboard provider change and
/// silently *overrides* the endpoint Hermes would otherwise resolve from
/// `provider` (resolution priority: explicit args → `auxiliary.<task>.base_url`
/// → `auto`). After changing a slot's provider through the dashboard we clear
/// that stale override so the slot routes to its provider's own endpoint.
public enum AuxiliaryModelConfig {
    /// Returns `config` with `auxiliary.<task>.base_url` removed — for one task,
    /// or every task when `task` is `nil`. Every other key (sibling tasks, the
    /// slot's `provider`/`model`, unrelated top-level config) is preserved.
    ///
    /// When there's nothing to clear (no `auxiliary` mapping, no matching slot,
    /// or no `base_url` on it) the value returned is equal to the input, so a
    /// caller can compare for equality and skip a needless config write.
    public static func clearingBaseURL(forTask task: String?, in config: JSONValue) -> JSONValue {
        guard case var .object(root) = config,
              case var .object(auxiliary) = root["auxiliary"] else {
            return config
        }

        func clearSlot(_ key: String) {
            guard case var .object(slot) = auxiliary[key], slot["base_url"] != nil else { return }
            slot.removeValue(forKey: "base_url")
            auxiliary[key] = .object(slot)
        }

        if let task {
            clearSlot(task)
        } else {
            for key in auxiliary.keys { clearSlot(key) }
        }

        root["auxiliary"] = .object(auxiliary)
        return .object(root)
    }
}
