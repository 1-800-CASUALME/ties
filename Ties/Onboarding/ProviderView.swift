import SwiftUI
import TiesCore

/// Sixth screen of setup: pick the AI that reads the scanned pages, fill in whatever that
/// provider needs (an API key, or a base URL and model for a local server), and prove it
/// answers before moving on.
///
/// Detection runs for the whole catalogue as the screen appears, so providers already
/// installed on this Mac show a green dot within a second or two and one of them can be
/// preselected without the user hunting for it.
struct ProviderView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state

    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var modelName = ""
    @State private var validating = false
    @State private var validationError: String?

    /// The tiers in catalogue order; each becomes one row of the grid, divided from the next.
    private let tiers: [ProviderTier] = [.onDevice, .freeCloud, .cli, .local, .paidCloud, .custom]

    private var selectedSpec: ProviderSpec? {
        state.providerId.flatMap(ProviderCatalog.spec)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Choose your AI")
                .font(.title2.weight(.semibold))

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(tiers, id: \.self) { tier in
                        grid(for: tier)
                        if tier != tiers.last {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            details
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .padding(.bottom, 4)
        .task { await detectAll() }
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(for tier: ProviderTier) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 12) {
            ForEach(ProviderCatalog.all.filter { $0.tier == tier }) { spec in
                LogoTile(
                    spec,
                    detected: state.detections[spec.id],
                    selected: state.providerId == spec.id
                ) {
                    select(spec.id)
                }
            }
        }
    }

    // MARK: - Selected provider

    @ViewBuilder
    private var details: some View {
        VStack(spacing: 10) {
            if let spec = selectedSpec {
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

                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                PrimaryButton("Continue") { validateAndContinue() }
                    .disabled(validating)
                    .overlay(alignment: .trailing) {
                        if validating {
                            ProgressView()
                                .controlSize(.small)
                                .offset(x: 28)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: state.providerId)
        .animation(.snappy, value: validationError)
        .onChange(of: apiKey) { _, key in saveAPIKey(key) }
        .onChange(of: baseURL) { _, _ in saveConfig() }
        .onChange(of: modelName) { _, _ in saveConfig() }
    }

    // MARK: - Detection

    /// Probes every catalogue entry at once rather than in sequence: the slowest rules shell
    /// out or wait on a local HTTP timeout, and run one after another they would add up to
    /// most of a minute. Each result is written as it lands so dots appear progressively.
    private func detectAll() async {
        await withTaskGroup(of: (String, DetectResult).self) { group in
            for spec in ProviderCatalog.all {
                group.addTask { [model] in (spec.id, await model.detect(spec)) }
            }
            for await (id, result) in group {
                state.detections[id] = result
            }
        }
        preselect()
    }

    /// Apple Intelligence if this Mac has it, Gemini otherwise — the free cloud provider with
    /// the least friction. Never overrides a choice the user (or an earlier visit) has made.
    private func preselect() {
        guard state.providerId == nil else { return }
        if case .available = state.detections["apple"] {
            select("apple")
        } else {
            select("gemini")
        }
    }

    // MARK: - Actions

    private func select(_ id: String) {
        state.providerId = id
        model.selectedProviderId = id
        validationError = nil
        loadFields(for: id)
    }

    /// Reloads the editable fields from the Keychain and saved config so switching providers
    /// never shows one provider's key or base URL under another's name.
    private func loadFields(for id: String) {
        let config = model.providerConfig(for: id)
        let spec = ProviderCatalog.spec(id)
        apiKey = Keychain.get(account: id) ?? ""
        baseURL = config?.baseURL ?? spec?.defaultBaseURL ?? ""
        modelName = config?.model ?? spec?.defaultModel ?? ""
    }

    private func saveAPIKey(_ key: String) {
        guard let id = state.providerId else { return }
        if key.isEmpty {
            Keychain.delete(account: id)
        } else {
            try? Keychain.set(key, account: id)
        }
    }

    private func saveConfig() {
        guard let id = state.providerId else { return }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.setProviderConfig(
            ProviderConfig(id: id, baseURL: base.isEmpty ? nil : base, model: name.isEmpty ? nil : name)
        )
    }

    /// Builds the chosen provider and makes it answer one throwaway prompt. A key that is
    /// wrong, a local server that isn't running, or a CLI that isn't installed all surface
    /// here rather than halfway through the extraction.
    private func validateAndContinue() {
        validating = true
        validationError = nil
        Task {
            do {
                let provider = try model.makeProvider()
                try await provider.validate()
                validating = false
                state.next()
            } catch {
                validating = false
                validationError = describe(error)
            }
        }
    }

    /// `ProviderError` carries no user-facing text of its own, and its `localizedDescription`
    /// is the unhelpful generic one, so each case gets a sentence here.
    private func describe(_ error: Error) -> String {
        guard let error = error as? ProviderError else { return error.localizedDescription }
        switch error {
        case .unauthorized:
            return "That API key was rejected."
        case .badResponse(let detail):
            return detail
        case .notInstalled(let name):
            return "\(name) isn't installed on this Mac."
        case .unavailable(let detail):
            return "\(detail) isn't available on this Mac."
        case .contextTooLarge:
            return "The provider turned the request down as too long."
        }
    }
}
