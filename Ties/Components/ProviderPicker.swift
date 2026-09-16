import SwiftUI
import TiesCore

/// The provider catalogue as a grid of logos, one row of tiles per tier, divided from the next.
///
/// Shared by setup's Choose-your-AI screen and Settings' Providers tab: they show the same
/// catalogue and the same green dots, and differ only in what selecting one leads to. Detection
/// is the caller's to run — the wizard keeps its own copy of the results.
struct ProviderGrid: View {
    let detections: [String: DetectResult]
    let selectedId: String?
    let onSelect: (String) -> Void

    /// The tiers in catalogue order; each becomes one row of the grid.
    private let tiers: [ProviderTier] = [.onDevice, .freeCloud, .cli, .local, .paidCloud, .custom]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(tiers, id: \.self) { tier in
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 12) {
                    ForEach(ProviderCatalog.all.filter { $0.tier == tier }) { spec in
                        LogoTile(
                            spec,
                            detected: detections[spec.id],
                            selected: selectedId == spec.id
                        ) {
                            onSelect(spec.id)
                        }
                    }
                }
                if tier != tiers.last {
                    Divider()
                }
            }
        }
    }
}

/// Whatever the chosen provider needs before it can answer: an API key for a cloud one, a base
/// URL and model for a local server or a custom endpoint, and nothing at all for a CLI or for
/// Apple Intelligence.
///
/// Every field writes straight through as it is typed — the key to the Keychain under the
/// provider's id, the rest to the provider's saved config — so there is no Save button and
/// nothing to lose by closing the window. Switching provider reloads all three from storage, so
/// one provider's key can never appear under another's name.
struct ProviderFields: View {
    @Environment(AppModel.self) private var model

    let spec: ProviderSpec

    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var modelName = ""

    var body: some View {
        VStack(spacing: 10) {
            if spec.needsAPIKey {
                HStack(spacing: 12) {
                    SecureField("API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    if let url = spec.apiKeyURL.flatMap(URL.init(string:)) {
                        Link(destination: url) {
                            Label("Get a key", systemImage: "arrow.up.right.square")
                        }
                        .font(.callout)
                    }
                }
            }

            if spec.tier == .local || spec.tier == .custom {
                HStack(spacing: 12) {
                    TextField("Base URL", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $modelName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                }
            }
        }
        .onChange(of: spec.id, initial: true) { loadFields() }
        .onChange(of: apiKey) { _, key in saveAPIKey(key) }
        .onChange(of: baseURL) { saveConfig() }
        .onChange(of: modelName) { saveConfig() }
    }

    private func loadFields() {
        let config = model.providerConfig(for: spec.id)
        apiKey = Keychain.get(account: spec.id) ?? ""
        baseURL = config?.baseURL ?? spec.defaultBaseURL ?? ""
        modelName = config?.model ?? spec.defaultModel ?? ""
    }

    private func saveAPIKey(_ key: String) {
        if key.isEmpty {
            Keychain.delete(account: spec.id)
        } else {
            try? Keychain.set(key, account: spec.id)
        }
    }

    private func saveConfig() {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setProviderConfig(
            ProviderConfig(id: spec.id, baseURL: base.isEmpty ? nil : base, model: name.isEmpty ? nil : name)
        )
    }
}
