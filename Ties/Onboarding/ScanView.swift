import SwiftUI
import TiesCore

/// Fourth screen of setup: the research itself, running while the user watches it happen.
///
/// The scanner is started here and kept on `WizardState`, so the pause/resume/stop buttons act
/// on the same actor the stream came from, and is cleared again the moment the stream ends —
/// a scanner left behind would make a second visit to this screen sit and watch a run that is
/// already over.
///
/// Each progress event re-reads the job table (one small query, and it drives every row's
/// shimmer) and the best candidate for the single person the event names. The whole
/// best-candidate map costs a statement per person, so it is read only at the start and once
/// the run has finished.
struct ScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state

    /// The selected contacts, in list order — also the order they are scanned in.
    @State private var people: [Person] = []
    /// The scan job state per person id, as of the last refresh.
    @State private var jobStates: [String: Job.State] = [:]
    /// Ids whose scan job has reached a terminal state, so their row can stop shimmering.
    @State private var done: Set<String> = []
    @State private var best: [String: Candidate] = [:]
    /// Display name back to person id: a progress event carries only a name, and this is how it
    /// becomes the one row worth re-reading.
    @State private var idsByName: [String: String] = [:]
    @State private var paused = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ProgressCaptionView(
                progress: state.scanProgress,
                onPause: pause,
                onResume: resume,
                onCancel: stop,
                paused: paused
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            ContactListView(people: people, query: .constant("")) { person in
                trailing(person)
            }

            // Kept in the layout from the start so the list doesn't jump when the first person
            // finishes; there is simply nothing partial to continue with until then.
            Button("Continue with partial results", action: stop)
                .controlSize(.large)
                .padding(.vertical, 16)
                .opacity(done.isEmpty ? 0 : 1)
                .disabled(done.isEmpty)
                .accessibilityHidden(done.isEmpty)
                .animation(.snappy, value: done.isEmpty)
        }
        .padding(.top, 24)
        .task { await scan() }
    }

    @ViewBuilder
    private func trailing(_ person: Person) -> some View {
        if done.contains(person.id) {
            let candidate = best[person.id]
            ConfidencePill(score: candidate?.score ?? 0, status: candidate?.status ?? .pending)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 52, height: 18)
                .redacted(reason: .placeholder)
                .accessibilityLabel("Researching")
        }
    }

    // MARK: - The run

    /// Starts the one scan this screen is for and follows it to the end.
    ///
    /// Arriving on a scan that has already happened moves straight on: there would be nothing
    /// running to watch, and re-running the whole batch is not what landing back here means. A
    /// run that is genuinely still in flight already owns a stream that will advance the wizard
    /// when it ends, so this call leaves it alone rather than starting a second one.
    private func scan() async {
        load()

        if scanFinished {
            state.next()
            return
        }

        guard state.scanner == nil else { return }

        let scanner = model.makeScanner()
        state.scanner = scanner

        for await progress in await scanner.run(personIds: scanOrder) {
            guard !Task.isCancelled else { return }
            state.scanProgress = progress
            refresh(progress)
        }

        // Cleared whether the run finished on its own or the user stopped it, so nothing later
        // mistakes a spent scanner for one still working.
        state.scanner = nil

        guard !Task.isCancelled else { return }
        state.next()
    }

    /// Whether every selected person already has a scan job that has started — so this batch has
    /// been run, and the rows on screen are its results rather than work in progress.
    private var scanFinished: Bool {
        guard !state.selectedIds.isEmpty else { return false }
        return state.selectedIds.allSatisfy { id in
            guard let jobState = jobStates[id] else { return false }
            return jobState != .queued
        }
    }

    /// Who to scan, in the order they are listed. Falls back to the raw selection if the people
    /// couldn't be read, so a failed list load can't silently scan nobody.
    private var scanOrder: [String] {
        people.isEmpty ? Array(state.selectedIds) : people.map(\.id)
    }

    private func pause() {
        paused = true
        Task { await state.scanner?.pause() }
    }

    private func resume() {
        paused = false
        Task { await state.scanner?.resume() }
    }

    /// Stops scheduling new people. Whoever is in flight still finishes, the stream then ends,
    /// and `scan()` moves the wizard on with whatever was found.
    private func stop() {
        Task { await state.scanner?.cancel() }
    }

    // MARK: - Reading back what the scan wrote

    private func load() {
        do {
            let selected = try model.store.allPeople().filter { state.selectedIds.contains($0.id) }
            people = selected
            idsByName = Dictionary(
                selected.map { ($0.displayName, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )
            try refreshJobs()
            best = try model.store.bestCandidatesByPerson()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The per-event refresh: every row's job state, and the best candidate for only the person
    /// this event is about. The full map is a statement per person, far too much to run on the
    /// main actor several times a second, so it waits for the end of the run.
    private func refresh(_ progress: ScanProgress) {
        do {
            try refreshJobs()
            if progress.finished {
                best = try model.store.bestCandidatesByPerson()
            } else if let id = progress.currentName.flatMap({ idsByName[$0] }) {
                // Assigning nil removes the key, which is what a person with no candidate means.
                best[id] = try model.store.bestCandidate(personId: id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshJobs() throws {
        let jobs = try model.store.jobs(kind: .scan)
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
