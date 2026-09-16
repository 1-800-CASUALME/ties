import SwiftUI
import TiesCore

/// Seventh screen of setup: the AI reading everything the scan collected and writing one
/// profile per person, watched as it happens.
///
/// The twin of `ScanView`, with three differences. The extractor can only be stopped, never
/// held, so there is no pause control. Building it can fail before any work starts — the
/// provider is assembled from the key and config chosen one screen earlier — so that failure is
/// shown here with the way back to the AI picker, which the wizard's own Back button doesn't
/// offer on this step. And every person here costs an AI call, so anyone whose extract job is
/// already `.done` is left out of the run: Review sends the same selection forward every time it
/// is passed, and re-running someone would spend a second call to overwrite the profile we have.
///
/// Each progress event re-reads the job table (one small query, and it drives every row's
/// shimmer) and the profile of the person the event names. The whole profile map is a statement
/// per person, so it is read only at the start and once the run has finished.
struct ExtractView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state

    /// The people picked on the Review screen, in list order — also the order they run in.
    @State private var people: [Person] = []
    /// The extract job state per person id, as of the last refresh.
    @State private var jobStates: [String: Job.State] = [:]
    /// Ids whose extract job has reached a terminal state, so their row can stop shimmering.
    @State private var done: Set<String> = []
    @State private var profiles: [String: Profile] = [:]
    /// Display name back to person ids: a progress event carries only a name, and this is how it
    /// becomes the rows worth re-reading. Two contacts can share a name, so both get refreshed.
    @State private var idsByName: [String: [String]] = [:]
    @State private var errorMessage: String?
    /// True when it was the provider that couldn't be built, so nothing ran at all and the only
    /// useful move is back to the AI picker.
    @State private var providerFailed = false

    /// Nobody was picked on the Review screen — which a jump straight to this dot can also
    /// mean. There is no run to watch and nothing to report, so the screen says so and waits.
    private var nothingToExtract: Bool {
        state.selectedForExtract.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if nothingToExtract {
                nothingToExtractView
            } else {
                run
            }
        }
        .padding(.top, 24)
        .task { await extract() }
    }

    private var nothingToExtractView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("Nothing to extract", systemImage: "tray")
            } description: {
                Text("Nobody is picked, so the AI has nothing to read. Pick people on the Review step, or carry on.")
            }
            PrimaryButton("Continue") { state.next() }
                .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var run: some View {
        ProgressCaptionView(
            progress: state.extractProgress,
            startedAt: state.extractStartedAt,
            work: .extract,
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
            .accessibilityHidden(done.isEmpty)
            .animation(.snappy, value: done.isEmpty)
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

    /// Starts the one extraction this screen is for and follows it to the end.
    ///
    /// A run that is genuinely still in flight already owns a stream that will advance the
    /// wizard when it ends, so this call watches it rather than starting a second one. Arriving
    /// with nothing left to extract — everyone selected has already been written up — moves
    /// straight on, with the finished rows on screen while it does.
    private func extract() async {
        // Nothing picked at all: the screen says so and leaves the move to the user, rather than
        // skipping past a step they came to on purpose.
        guard !nothingToExtract else { return }
        load()

        guard state.extractor == nil else {
            await follow()
            return
        }

        let pending = pendingOrder
        guard !pending.isEmpty else {
            state.next()
            return
        }

        let extractor: Extractor
        do {
            extractor = try model.makeExtractor()
        } catch {
            errorMessage = "Couldn't start the AI. \(describe(error))"
            providerFailed = true
            return
        }
        state.extractor = extractor
        state.extractStartedAt = .now

        for await progress in await extractor.run(personIds: pending) {
            guard !Task.isCancelled else { return }
            state.extractProgress = progress
            refresh(progress)
        }

        // Cleared whether the run finished on its own or the user stopped it, so a later visit
        // can tell a spent extractor from one still working.
        state.extractor = nil

        // The step check is not redundant: a screen being pushed off is still alive (and its
        // task still running) for the length of the transition, so a run that ends in that
        // window would otherwise push the wizard on a second time.
        guard !Task.isCancelled, state.step == .extract else { return }
        state.next()
    }

    /// Watches a run this screen didn't start, which is what a rebuilt view arrives to. Its own
    /// loop owns the stream and moves the wizard on when it ends, so this only keeps the rows
    /// current — unless that loop went away with the view that ran it, in which case nobody is
    /// left to notice the end, and seeing the batch out is this screen's job rather than sitting
    /// in front of a run that will never finish.
    private func follow() async {
        while state.extractor != nil {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, state.step == .extract else { return }
            reload()

            guard extractOrder.allSatisfy(done.contains) else { continue }
            state.extractor = nil
            state.next()
            return
        }
    }

    /// Who to write up, in the order they are listed. Falls back to the raw selection if the
    /// people couldn't be read, so a failed list load can't silently extract nobody.
    private var extractOrder: [String] {
        people.isEmpty ? Array(state.selectedForExtract) : people.map(\.id)
    }

    /// The run itself: everyone in `extractOrder` who hasn't already been written up. A job that
    /// failed or was skipped is worth another try; one that is `.done` is a profile we would
    /// only be paying an AI call to replace.
    private var pendingOrder: [String] {
        extractOrder.filter { jobStates[$0] != .done }
    }

    /// Stops starting new people. Whoever is in flight still finishes, the stream then ends,
    /// and `extract()` moves the wizard on with whatever was written.
    private func stop() {
        Task { await state.extractor?.cancel() }
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
            let selected = try model.store.allPeople().filter { state.selectedForExtract.contains($0.id) }
            people = selected
            idsByName = Dictionary(grouping: selected, by: \.displayName).mapValues { $0.map(\.id) }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The per-event refresh: every row's job state, and the profile of only the person this
    /// event is about. The full map is a statement per person, far too much to run on the main
    /// actor several times a second, so it waits for the end of the run.
    private func refresh(_ progress: ScanProgress) {
        do {
            try refreshJobs()
            if progress.finished {
                profiles = try model.store.profilesByPerson()
            } else if let name = progress.currentName {
                for id in idsByName[name] ?? [] {
                    // Assigning nil removes the key, which is what a person with no profile means.
                    profiles[id] = try model.store.profile(personId: id)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Everything the rows are drawn from, in full: for the first render, and for anywhere the
    /// screen has no single person's event to go on.
    private func reload() {
        do {
            try refreshJobs()
            profiles = try model.store.profilesByPerson()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshJobs() throws {
        let jobs = try model.store.jobs(kind: .extract)
        jobStates = Dictionary(
            jobs.map { ($0.personId, $0.state) },
            uniquingKeysWith: { _, latest in latest }
        )
        done = Set(
            jobStates
                .filter { $0.value == .done || $0.value == .failed || $0.value == .skipped }
                .keys
        )
    }
}
