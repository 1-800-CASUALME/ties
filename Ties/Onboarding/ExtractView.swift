import SwiftUI
import TiesCore

/// Seventh screen of setup: the AI reading everything the scan collected and writing one
/// profile per person, watched as it happens.
///
/// The twin of `ScanView`, with two differences. The extractor can only be stopped, never held,
/// so there is no pause control. And building it can fail before any work starts — the provider
/// is assembled from the key and config chosen one screen earlier — so that failure is shown
/// here with the way back to the AI picker, which the wizard's own Back button doesn't offer on
/// this step.
struct ExtractView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state

    /// The people picked on the Review screen, in list order — also the order they run in.
    @State private var people: [Person] = []
    /// Ids whose extract job has reached a terminal state, so their row can stop shimmering.
    @State private var done: Set<String> = []
    @State private var profiles: [String: Profile] = [:]
    /// The one extractor this screen started, kept so Stop acts on the run the stream came from.
    @State private var extractor: Extractor?
    @State private var errorMessage: String?
    /// True when it was the provider that couldn't be built, so nothing ran at all and the only
    /// useful move is back to the AI picker.
    @State private var providerFailed = false

    var body: some View {
        VStack(spacing: 0) {
            ProgressCaptionView(
                progress: state.extractProgress,
                onCancel: stop,
                paused: false,
                showsPause: false
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if let errorMessage {
                VStack(spacing: 8) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    if providerFailed {
                        Button("Choose a different AI") { state.back() }
                            .controlSize(.large)
                    }
                }
                .padding(.bottom, 8)
            }

            ContactListView(
                people: people,
                query: .constant(""),
                subtitle: { profiles[$0.id]?.facts.occupation }
            ) { person in
                trailing(person)
            }

            // In the layout from the start so the list doesn't jump when the first profile
            // lands; until then there is nothing partial to continue with.
            Button("Continue with partial results", action: stop)
                .controlSize(.large)
                .padding(.vertical, 16)
                .opacity(done.isEmpty ? 0 : 1)
                .disabled(done.isEmpty)
                .animation(.snappy, value: done.isEmpty)
        }
        .padding(.top, 24)
        .task { await extract() }
    }

    @ViewBuilder
    private func trailing(_ person: Person) -> some View {
        if done.contains(person.id) {
            if profiles[person.id] != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Profile written")
            } else {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
                    .help("Nothing could be written up for \(person.displayName)")
                    .accessibilityLabel("Nothing found")
            }
        } else {
            // Stands in for the occupation the row is about to show.
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 88, height: 18)
                .redacted(reason: .placeholder)
                .accessibilityLabel("Reading")
        }
    }

    // MARK: - The run

    /// Starts the one extraction this screen is for and follows it to the end. `extractor` is
    /// the guard against a second start if the view is ever rebuilt.
    private func extract() async {
        load()
        guard extractor == nil else { return }

        let extractor: Extractor
        do {
            extractor = try model.makeExtractor()
        } catch {
            errorMessage = "Couldn't start the AI. \(describe(error))"
            providerFailed = true
            return
        }
        self.extractor = extractor

        for await progress in await extractor.run(personIds: extractOrder) {
            guard !Task.isCancelled else { return }
            state.extractProgress = progress
            refresh()
        }

        guard !Task.isCancelled else { return }
        state.next()
    }

    /// Who to write up, in the order they are listed. Falls back to the raw selection if the
    /// people couldn't be read, so a failed list load can't silently extract nobody.
    private var extractOrder: [String] {
        people.isEmpty ? Array(state.selectedForExtract) : people.map(\.id)
    }

    /// Stops starting new people. Whoever is in flight still finishes, the stream then ends,
    /// and `extract()` moves the wizard on with whatever was written.
    private func stop() {
        Task { await extractor?.cancel() }
    }

    /// `ProviderError`'s own `localizedDescription` is the generic one, so the cases
    /// `makeExtractor()` can throw get a sentence each.
    private func describe(_ error: Error) -> String {
        switch error as? ProviderError {
        case .unauthorized: "That API key was rejected."
        case .badResponse(let detail): detail
        case .notInstalled(let name): "\(name) isn't installed on this Mac."
        case .unavailable(let detail): "\(detail) isn't available on this Mac."
        default: error.localizedDescription
        }
    }

    // MARK: - Reading back what the extraction wrote

    private func load() {
        do {
            people = try model.store.allPeople().filter { state.selectedForExtract.contains($0.id) }
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-read on every progress event: two small table scans, cheaper than any
    /// change-notification machinery and already on an event we get for free.
    private func refresh() {
        do {
            let jobs = try model.store.jobs(kind: .extract)
            done = Set(
                jobs
                    .filter { $0.state == .done || $0.state == .failed || $0.state == .skipped }
                    .map(\.personId)
            )
            profiles = try model.store.profilesByPerson()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
