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

    @State private var validating = false
    @State private var validationError: String?
    /// The in-flight `validate()` call, held so leaving the step or changing provider can
    /// cancel it instead of letting it finish against a screen that has moved on.
    @State private var validationTask: Task<Void, Never>?

    private var selectedSpec: ProviderSpec? {
        state.providerId.flatMap(ProviderCatalog.spec)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Choose your AI")
                .font(.title2.weight(.semibold))

            ScrollView {
                ProviderGrid(
                    detections: state.detections,
                    selectedId: state.providerId,
                    onSelect: select
                )
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)

            details
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .padding(.bottom, 4)
        .task { await detectAll() }
        .onDisappear(perform: cancelValidation)
    }

    // MARK: - Selected provider

    @ViewBuilder
    private var details: some View {
        VStack(spacing: 10) {
            if let spec = selectedSpec {
                ProviderFields(spec: spec)

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
        cancelValidation()
        state.providerId = id
        model.selectedProviderId = id
        validationError = nil
    }

    /// Builds the chosen provider and makes it answer one throwaway prompt. A key that is
    /// wrong, a local server that isn't running, or a CLI that isn't installed all surface
    /// here rather than halfway through the extraction.
    ///
    /// The call can take seconds against a slow provider, and Back stays enabled throughout,
    /// so the task is kept rather than fired and forgotten — see `finishValidation`.
    private func validateAndContinue() {
        guard let id = state.providerId else { return }
        cancelValidation()
        validating = true
        validationError = nil
        validationTask = Task {
            do {
                let provider = try model.makeProvider()
                try await provider.validate()
                finishValidation(for: id, error: nil)
            } catch {
                finishValidation(for: id, error: describe(error))
            }
        }
    }

    /// Applies a finished validation only while it still describes what is on screen: the run
    /// wasn't cancelled, the wizard is still on this step, and the same provider is chosen.
    ///
    /// Without that check a user who presses Continue and then Back gets silently pushed
    /// forward from whatever screen they backed into, seconds later, by a call they had
    /// already walked away from — `WizardState` is shared, so `next()` moves the wizard
    /// wherever it now happens to be.
    private func finishValidation(for id: String, error: String?) {
        validating = false
        guard !Task.isCancelled, state.step == .provider, state.providerId == id else { return }
        if let error {
            validationError = error
        } else {
            state.next()
        }
    }

    /// Abandons an in-flight validation and frees the button, for when the answer has stopped
    /// mattering: the step is being left, or a different provider has been picked.
    private func cancelValidation() {
        validationTask?.cancel()
        validationTask = nil
        validating = false
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
