import SwiftUI

/// Pure, UI-free decision logic for ``RevealableSecretField`` — split out so the
/// (historically bug-prone) reveal/hide rules are unit-tested without a running
/// view. The widget renders the result; these functions decide it.
enum RevealableSecret {
    /// What an eye tap should do, given the current state.
    enum Action: Equatable {
        /// Flip cleartext visibility to the associated value (no fetch). For a
        /// secret this swaps `SecureField`⇄`TextField`; the text is retained, so
        /// re-showing never needs a refetch. For a non-secret it's a no-op
        /// visually (the field is always cleartext).
        case toggleMask(Bool)
        /// Fetch the stored value on demand (rate-limited server call), then show
        /// it. Only chosen when the field is empty and a stored value exists.
        case fetch
    }

    static func action(showKey: Bool, textIsEmpty: Bool, canReveal: Bool) -> Action {
        if showKey { return .toggleMask(false) }
        if textIsEmpty, canReveal { return .fetch }
        return .toggleMask(true)
    }

    /// Whether the eye is offered. A secret always gets one (mask toggle / fetch);
    /// a non-secret gets one only while empty *and* fetchable — a one-way "load
    /// the current value" affordance. Once a non-secret value is shown there's
    /// nothing to hide (it isn't sensitive), so the eye drops away.
    static func showsEye(isSecret: Bool, canReveal: Bool, textIsEmpty: Bool) -> Bool {
        isSecret || (canReveal && textIsEmpty)
    }
}

/// The one secret-input control shared by Environment, Messaging, and the custom
/// endpoint form. A `SecureField`/`TextField` pair plus an eye that either
/// toggles cleartext visibility (secrets) or fetches the stored value on demand
/// (`reveal`). All the reveal/hide subtlety lives here — see ``RevealableSecret``
/// for the pure rules — so the call sites just bind a `text` and a `reveal`
/// closure and pick a policy via `isSecret` / `canReveal`.
struct RevealableSecretField: View {
    @Binding var text: String
    var placeholder: String
    /// Mask with a `SecureField` when hidden (a true secret). Non-secrets render
    /// a plain `TextField` but still get the eye to load a server-masked value.
    var isSecret: Bool
    /// A stored value exists worth fetching (e.g. the var is set / the endpoint
    /// has a key). When false and the field is empty the eye merely toggles
    /// typed-text visibility (secrets) or is hidden (non-secrets).
    var canReveal: Bool
    /// Fetches the stored plaintext. `nil` = nothing to show / failed (the
    /// closure reports its own error). Default returns nil so a field that never
    /// fetches (always-typed) needn't supply one.
    var reveal: () async -> String? = { nil }
    /// Gates the eye off entirely (e.g. a collapsed Environment row still renders
    /// the field but shouldn't offer reveal until expanded).
    var revealAvailable: Bool = true
    /// Font for the text field. Defaults to the compact caption used by the
    /// Environment/Messaging rows; the endpoint form passes a body size. Set
    /// here (not by an outer `.font`) since the inner field's own modifier would
    /// otherwise win over a call-site one.
    var font: Font = .system(.caption, design: .monospaced)
    /// Optional external focus binding so a parent can react to focus (expand a
    /// row) and gate keyboard shortcuts on it.
    var focus: FocusState<Bool>.Binding? = nil
    var onFocus: (() -> Void)? = nil
    /// Bump to re-mask a revealed secret — e.g. on a manual refresh, so a
    /// revealed value doesn't stay in cleartext after a reload. The typed/revealed
    /// `text` is kept (now masked behind the `SecureField`), not cleared.
    var remaskToken: Int = 0

    @State private var showKey = false
    @State private var revealing = false
    /// Bumped whenever the field's editing context goes away (`revealAvailable`
    /// drops) so an in-flight reveal started beforehand discards its result
    /// instead of un-masking a now-collapsed row. Read live after the await
    /// (via `@State`) even though the captured view struct is stale.
    @State private var revealGeneration = 0

    var body: some View {
        HStack(spacing: 4) {
            field
            if revealAvailable,
               RevealableSecret.showsEye(isSecret: isSecret, canReveal: canReveal, textIsEmpty: text.isEmpty) {
                eye
            }
        }
        // Re-mask whenever the field empties — a save/collapse clears `text`
        // externally, and a secret must never reappear as cleartext afterwards.
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty { showKey = false }
        }
        // Re-mask a revealed secret when the parent signals a refresh.
        .onChange(of: remaskToken) { _, _ in
            showKey = false
        }
        // When the field's editing context goes away (e.g. an Environment row
        // collapses, which still renders the field), invalidate any in-flight
        // reveal so its late result can't un-mask the now-collapsed row, and
        // re-mask immediately.
        .onChange(of: revealAvailable) { _, available in
            if !available {
                revealGeneration += 1
                showKey = false
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let base = Group {
            if isSecret, !showKey {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(font)

        if let focus {
            base
                .focused(focus)
                .onChange(of: focus.wrappedValue) { _, isFocused in
                    if isFocused { onFocus?() }
                }
        } else {
            base
        }
    }

    private var eye: some View {
        Button {
            Task { await handleEyeTap() }
        } label: {
            if revealing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: showKey ? "eye.slash" : "eye")
            }
        }
        .buttonStyle(.borderless)
        .disabled(revealing)
        .accessibilityLabel(showKey ? "Hide value" : "Show value")
        .help(showKey ? "Hide the value" : "Reveal the current value")
    }

    private func handleEyeTap() async {
        switch RevealableSecret.action(showKey: showKey, textIsEmpty: text.isEmpty, canReveal: canReveal) {
        case let .toggleMask(value):
            showKey = value
        case .fetch:
            let generation = revealGeneration
            revealing = true
            let value = await reveal()
            revealing = false
            // Discard the result if the field's context went away mid-fetch —
            // applying it would un-mask a row the user already collapsed. The
            // captured view struct is stale, but `revealGeneration` is `@State`
            // so this reads the live value.
            guard generation == revealGeneration else { return }
            if let value {
                text = value
                showKey = true
            }
        }
    }
}
