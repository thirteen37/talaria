import HermesKit
import SwiftUI

/// Add/edit sheet for a custom OpenAI-compatible endpoint. Drives
/// `ModelsHarness.saveEndpoint(_:newKey:)`. The slug (stable id) is derived
/// from the name on first save and never shown — the Name field is the only
/// editable label. The API key is write-mostly: an untouched field keeps the
/// stored key ("leave blank to keep"); editing one stores a fresh secret in
/// `~/.hermes/.env`.
struct CustomEndpointForm: View {
    let harness: ModelsHarness
    /// The endpoint being edited, or nil when adding a new one.
    let existing: CustomEndpoint?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var baseURL: String
    @State private var discoverModels: Bool
    @State private var models: [String]
    @State private var newModel: String = ""
    /// Typed API key. Empty means "leave the stored key untouched" when editing,
    /// or "no key" when adding.
    @State private var keyInput: String = ""
    @State private var showKey: Bool = false
    @State private var revealing: Bool = false
    /// Inline error from a failed/empty reveal, so a transient failure is
    /// visible rather than looking like a cleared key.
    @State private var revealError: String?
    @State private var saving: Bool = false
    /// Inline error from a failed save, so the sheet stays open with the typed
    /// values (including a freshly-entered key) rather than dismissing on
    /// failure.
    @State private var saveError: String?

    init(harness: ModelsHarness, existing: CustomEndpoint?) {
        self.harness = harness
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _baseURL = State(initialValue: existing?.baseURL ?? "")
        _discoverModels = State(initialValue: existing?.discoverModels ?? true)
        _models = State(initialValue: existing?.models ?? [])
    }

    private var isEditing: Bool { existing != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Endpoint") {
                    TextField("Name", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .textContentType(.URL)
                        .font(.system(.body, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }

                Section {
                    apiKeyField
                    if let revealError {
                        Text(revealError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("API key")
                } footer: {
                    Text(apiKeyFooter)
                }

                Section {
                    Toggle("Auto-detect models", isOn: $discoverModels)
                    modelList
                    HStack {
                        TextField("Add model ID", text: $newModel)
                            .font(.system(.body, design: .monospaced))
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        Button("Add") { addModel() }
                            .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Add this model ID to the manual list")
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("With auto-detect on, Hermes fetches the model list from the endpoint. Manually-added IDs are merged in either way.")
                }

                if let saveError {
                    Section {
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit endpoint" : "Add endpoint")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .help("Discard changes")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .help("Save this endpoint")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    @ViewBuilder
    private var apiKeyField: some View {
        HStack {
            Group {
                if showKey {
                    TextField("API key", text: $keyInput)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                } else {
                    SecureField(isEditing ? "Leave blank to keep" : "API key", text: $keyInput)
                }
            }
            .font(.system(.body, design: .monospaced))

            Button {
                toggleReveal()
            } label: {
                if revealing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
            }
            .buttonStyle(.borderless)
            .disabled(revealing)
            .accessibilityLabel(revealAccessibilityLabel)
            .help(revealHelp)
        }
    }

    /// One control for both "show what I typed" and "fetch the stored key".
    /// When hidden and the field is empty but a key is stored, fetch it from
    /// `~/.hermes/.env`; otherwise just flip visibility of the typed value.
    private func toggleReveal() {
        if showKey {
            showKey = false
            return
        }
        if isEditing, existing?.hasAPIKey == true, keyInput.isEmpty {
            reveal()           // async: sets keyInput + showKey, or revealError
        } else {
            revealError = nil  // a prior failed reveal no longer applies to the typed key
            showKey = true
        }
    }

    private var revealHelp: String {
        if showKey { return "Hide the API key" }
        if isEditing, existing?.hasAPIKey == true, keyInput.isEmpty {
            return "Reveal the stored API key"
        }
        return "Show the API key"
    }

    private var revealAccessibilityLabel: String {
        showKey ? "Hide API key" : "Show API key"
    }

    private var apiKeyFooter: String {
        if isEditing {
            return "Stored in ~/.hermes/.env and referenced as ${…} — never written to config.yaml. Leave blank to keep the current key."
        }
        return "Stored in ~/.hermes/.env and referenced as ${…} — never written to config.yaml."
    }

    @ViewBuilder
    private var modelList: some View {
        if models.isEmpty {
            Text("No manual models.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(models, id: \.self) { model in
                HStack {
                    Text(model)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        models.removeAll { $0 == model }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove model \(model)")
                    .help("Remove “\(model)” from the manual list")
                }
            }
        }
    }

    private func addModel() {
        let trimmed = newModel.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !models.contains(trimmed) else { newModel = ""; return }
        models.append(trimmed)
        newModel = ""
    }

    private func reveal() {
        guard let existing else { return }
        revealing = true
        revealError = nil
        Task {
            do {
                if let value = try await harness.revealEndpointKey(for: existing) {
                    keyInput = value
                    showKey = true
                } else {
                    revealError = "No stored key to reveal — the referenced variable may be unset."
                }
            } catch {
                revealError = error.localizedDescription
            }
            revealing = false
        }
    }

    private func save() {
        saving = true
        saveError = nil
        let endpoint = CustomEndpoint(
            slug: existing?.slug ?? "",
            name: name.trimmingCharacters(in: .whitespaces),
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            models: models,
            defaultModel: existing?.defaultModel,
            discoverModels: discoverModels,
            hasAPIKey: existing?.hasAPIKey ?? false,
            source: existing?.source ?? .providersDict(slug: "")
        )
        let trimmedKey = keyInput.trimmingCharacters(in: .whitespaces)
        let newKey = trimmedKey.isEmpty ? nil : trimmedKey
        Task {
            let ok = await harness.saveEndpoint(endpoint, newKey: newKey)
            saving = false
            if ok {
                dismiss()
            } else {
                // Keep the sheet (and the typed key) open so input isn't lost.
                saveError = harness.lastError ?? "Couldn’t save the endpoint."
            }
        }
    }
}
