import SwiftUI
import TiesCore

/// Fourth screen of setup: the research itself, running while the user watches it happen.
///
/// The scanner is started here and kept on `WizardState`, so the pause/resume/stop buttons act
/// on the same actor the stream came from. Every progress event is the cue to re-read the scan
/// jobs and the best candidate per person; both are small table scans, and doing them on an
/// event we already get is cheaper than any change-notification machinery.
struct ScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state

    /// The selected contacts, in list order — also the order they are scanned in.
    @State private var people: [Person] = []
    /// Ids whose scan job has reached a terminal state, so their row can stop shimmering.
    @State private var done: Set<String> = []
    @State private var best: [String: Candidate] = [:]
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

    /// Starts the one scan this screen is for and follows it to the end. `state.scanner` is the
    /// guard against a second start: `.task` runs again if the view is ever rebuilt, and a
    /// second `run` would only be rejected by the scanner anyway.
    private func scan() async {
        load()
        guard state.scanner == nil else { return }

        let scanner = model.makeScanner()
        state.scanner = scanner

        for await progress in await scanner.run(personIds: scanOrder) {
            guard !Task.isCancelled else { return }
            state.scanProgress = progress
            refresh()
        }

        guard !Task.isCancelled else { return }
        state.next()
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
            people = try model.store.allPeople().filter { state.selectedIds.contains($0.id) }
            errorMessage = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() {
        do {
            let jobs = try model.store.jobs(kind: .scan)
            done = Set(
                jobs
                    .filter { $0.state == .done || $0.state == .failed || $0.state == .skipped }
                    .map(\.personId)
            )
            best = try model.store.bestCandidatesByPerson()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
