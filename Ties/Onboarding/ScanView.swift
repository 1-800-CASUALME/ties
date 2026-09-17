import SwiftUI
import TiesCore

/// Fifth screen of setup: the research itself, running while the user watches it happen.
///
/// It starts with what this Mac already knows. Before a single page is fetched, the signal
/// collector reads the sources the user allowed on the Sources step — Contacts, Messages,
/// WhatsApp, Mail — for the same people, through the same caption (spec §3, §6); the web research
/// follows, and only it is re-run when the engine or the depth is changed mid-flight.
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
    /// The collect job state per person id. Kept apart from the scan's: the two passes run over
    /// the same people, and a person whose sources have been read is not thereby researched.
    @State private var collectStates: [String: Job.State] = [:]
    /// Ids whose scan job has reached a terminal state, so their row can stop shimmering.
    @State private var done: Set<String> = []
    @State private var best: [String: Candidate] = [:]
    /// Display name back to person id: a progress event carries only a name, and this is how it
    /// becomes the one row worth re-reading.
    @State private var idsByName: [String: String] = [:]
    /// The probe running right now for each person still in flight, by person id. Four people
    /// are scanned at once, so this is a map rather than one current stage: each row says what
    /// its own person is being searched on.
    @State private var stages: [String: String] = [:]
    /// Set by the first progress event of the run, which is what tells the hint below that the
    /// scan is demonstrably alive.
    @State private var started = false
    /// Set while the local sources are being read, which is the first half of this screen: the
    /// caption watches the collection until it ends, then the scan.
    @State private var collecting = false
    /// Shown only when three seconds pass with nothing back from the scanner: the first probe of
    /// the first person can take that long, and a screen with nothing on it but a still bar is
    /// the moment the user starts to wonder whether anything is running.
    @State private var showsHint = false
    @State private var paused = false
    /// Set when the engine changes under a running scan: the stream is stopped, and the run loop
    /// starts a fresh scanner over whoever is left instead of moving the wizard on.
    @State private var restartRequested = false
    /// The engine the user picked that has no key yet, which the sheet is asking for.
    @State private var askingKeyFor: SearchBackendChoice?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 12) {
                    Spacer()
                    ScanModePicker(mode: modeBinding)
                        .labelsHidden()
                        .fixedSize()
                    engineMenu
                }
                if model.usesWebSearchPool {
                    Text("Web search runs \(model.searchPoolSize) at a time. Tavily or Exa are faster.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            .animation(.snappy, value: model.usesWebSearchPool)

            ProgressCaptionView(
                progress: collecting ? state.collectProgress : state.scanProgress,
                startedAt: collecting ? state.collectStartedAt : state.scanStartedAt,
                work: collecting ? .collect : .research,
                onPause: pause,
                onResume: resume,
                onCancel: collecting ? stopCollecting : stop,
                paused: paused,
                // The collector reads a capped slice of a local store per person; there is
                // nothing long enough to hold, only something to stop.
                showsPause: !collecting
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            if showsHint {
                Label(
                    "Researching starts with Gravatar, then GitHub, the web, username sites, and their pages.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 8)
                .transition(.opacity)
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
        .task { await waitForFirstEvent() }
        .sheet(item: $askingKeyFor) { choice in
            SearchBackendKeySheet(choice: choice) { useIt in
                askingKeyFor = nil
                if useIt { switchTo(choice.id) }
            }
        }
    }

    // MARK: - How deep, and which engine

    /// How deep the research goes, changed here for the same reason the engine is: the moment
    /// a batch of hundreds is obviously going to take all afternoon is while watching it.
    /// Switching restarts the run over whoever is left, exactly as switching engine does.
    private var modeBinding: Binding<ScanMode> {
        Binding(
            get: { model.scanMode },
            set: { mode in
                guard mode != model.scanMode else { return }
                model.setScanMode(mode)
                restartScan()
            }
        )
    }

    /// The engine the research searches with, changeable here rather than only in Settings: the
    /// moment it is obviously not working is while watching it not work.
    private var engineMenu: some View {
        Menu {
            ForEach(SearchBackendChoice.all) { choice in
                Button { choose(choice) } label: {
                    if choice.id == model.searchBackendId {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
        } label: {
            Label(SearchBackendChoice.named(model.searchBackendId).name, systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which engine the research searches with")
        .accessibilityLabel("Search engine")
    }

    /// An engine that needs a key we haven't got asks for it first; a switch that quietly fell
    /// back to DuckDuckGo would look like the menu had done nothing at all.
    ///
    /// Picking the engine already running is the only no-op. The saved choice and the engine
    /// actually searching can differ — a key that has gone missing falls back to DuckDuckGo
    /// underneath — and picking the saved one again is then exactly how someone would try to
    /// put that right, so it must not be swallowed.
    private func choose(_ choice: SearchBackendChoice) {
        guard choice.id != model.searchBackendId || choice.id != model.activeSearchBackendId else { return }
        guard choice.hasKey else {
            askingKeyFor = choice
            return
        }
        switchTo(choice.id)
    }

    /// Saves the engine and starts the run again with it, over whoever hasn't been researched
    /// yet — the people already done were found with the old engine, and are done either way.
    private func switchTo(_ id: String) {
        model.setSearchBackend(id)
        restartScan()
    }

    /// Stops the scanner, which ends its stream; `runUntilDone()` then comes round with a fresh
    /// one built from whatever was just chosen, over whoever is still pending. Resuming first,
    /// because a paused run would otherwise sit there and the switch would look like nothing.
    private func restartScan() {
        restartRequested = true
        paused = false
        Task { await state.scanner?.cancel() }
    }

    /// Puts the hint up if the scanner hasn't said anything within three seconds, and leaves it
    /// alone once it has.
    private func waitForFirstEvent() async {
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, !started else { return }
        withAnimation(.snappy) { showsHint = true }
    }

    @ViewBuilder
    private func trailing(_ person: Person) -> some View {
        if done.contains(person.id) {
            let candidate = best[person.id]
            ConfidencePill(score: candidate?.score ?? 0, status: candidate?.status ?? .pending)
        } else if let stage = stages[person.id] {
            // What this person is being searched on right now, in the probe's own words, so a
            // row that sits there for a minute still says what it is doing.
            Text(stage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .accessibilityLabel("Searching \(stage)")
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

        guard state.scanner == nil, state.collector == nil else { return }

        await collect()
        guard !Task.isCancelled, state.step == .scan else { return }

        await runUntilDone()

        guard !Task.isCancelled, state.step == .scan else { return }
        state.next()
    }

    /// Reads the sources the user allowed, for the people about to be researched, before any of
    /// the web work starts: what Messages, WhatsApp and Mail already know about someone is free,
    /// certain, and makes every search that follows a better one.
    ///
    /// Statuses are re-checked first, because Full Disk Access may have been granted — or
    /// revoked — since the Sources step, and `makeSignalCollector()` builds from what is ready
    /// right now. A source that is off, missing, or locked is simply not in the run.
    private func collect() async {
        await model.sources.refresh()

        let collector = model.makeSignalCollector()
        state.collector = collector
        state.collectStartedAt = .now
        let pending = pendingCollection
        state.collectProgress = ScanProgress(completed: 0, total: pending.count)
        collecting = true

        // Whatever ends this — the stream running out, the screen going away, a jump to another
        // step — leaves the screen saying the same thing: nothing is collecting. Returning out
        // of the loop without this left the wizard holding a spent collector and the caption
        // stuck on a pass that had stopped.
        defer {
            state.collector = nil
            collecting = false
        }

        for await progress in await collector.run(personIds: pending) {
            guard !Task.isCancelled else { return }
            state.collectProgress = progress
            noteFirstEvent()
        }
    }

    /// Stops reading the local sources. Whoever is in flight finishes, the stream ends, and the
    /// research starts without waiting for the rest.
    private func stopCollecting() {
        Task { await state.collector?.cancel() }
    }

    /// One scanner per pass over the people still to research. Changing the engine stops the
    /// scanner, which ends the stream, and the loop comes round with a new one built from the
    /// engine that was just chosen — rather than the wizard moving on as it would for any other
    /// stopped run.
    private func runUntilDone() async {
        repeat {
            restartRequested = false
            let scanner = model.makeScanner()
            state.scanner = scanner
            state.scanStartedAt = .now

            for await progress in await scanner.run(personIds: pendingOrder) {
                guard !Task.isCancelled else { return }
                state.scanProgress = progress
                refresh(progress)
            }

            // Cleared whether the run finished on its own or the user stopped it, so nothing
            // later mistakes a spent scanner for one still working.
            state.scanner = nil
            // `Task.isCancelled` alone isn't enough: a screen being pushed off is still alive
            // (and its task still running) for the length of the transition, so a stream that
            // ends in that window would otherwise start a scanner nobody is left to cancel.
            guard !Task.isCancelled, state.step == .scan else { return }
        } while restartRequested && !pendingOrder.isEmpty
    }

    /// Whether every selected person already has a scan job that has started — so this batch has
    /// been run, and the rows on screen are its results rather than work in progress.
    private var scanFinished: Bool {
        guard !state.selectedIds.isEmpty else { return false }
        return state.selectedIds.allSatisfy { id in
            guard let jobState = jobStates[id] else { return false }
            // Only a job that actually ended counts. A `.running` row left behind by a crash
            // means the scan never finished, so it must run again.
            return jobState == .done || jobState == .failed || jobState == .skipped
        }
    }

    /// Who to scan, in the order they are listed. Falls back to the raw selection if the people
    /// couldn't be read, so a failed list load can't silently scan nobody.
    private var scanOrder: [String] {
        people.isEmpty ? Array(state.selectedIds) : people.map(\.id)
    }

    /// Who is actually left: anyone whose scan job isn't already `.done`. A person researched on
    /// an earlier visit — or before the engine was changed — has candidates already, and paying
    /// for them twice is the one thing a restart must not do. A job that failed or was skipped is
    /// worth another try, which is exactly what a different engine is for.
    private var pendingOrder: [String] {
        scanOrder.filter { jobStates[$0] != .done }
    }

    /// Who still needs their sources read. The collection keeps its own jobs, so this asks
    /// those: filtering on the scan's jobs made re-entering Research read Messages and Mail
    /// again for everyone it had already read them for.
    private var pendingCollection: [String] {
        scanOrder.filter { collectStates[$0] != .done }
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
        noteFirstEvent()
        do {
            try refreshJobs()
            noteStage(progress)
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

    /// The first event of either run is what proves something is happening, and takes the hint
    /// about what research does back down.
    private func noteFirstEvent() {
        guard !started else { return }
        started = true
        withAnimation(.snappy) { showsHint = false }
    }

    /// Keeps the per-row stage current: the person this event names is on the probe it names,
    /// and anyone whose job has ended has no stage left to show.
    private func noteStage(_ progress: ScanProgress) {
        withAnimation(.snappy) {
            if let name = progress.currentName, let id = idsByName[name] {
                stages[id] = progress.stage
            }
            stages = stages.filter { !done.contains($0.key) }
        }
    }

    private func refreshJobs() throws {
        let jobs = try model.store.jobs(kind: .scan)
        jobStates = Dictionary(
            jobs.map { ($0.personId, $0.state) },
            uniquingKeysWith: { _, latest in latest }
        )
        collectStates = Dictionary(
            try model.store.jobs(kind: .collect).map { ($0.personId, $0.state) },
            uniquingKeysWith: { _, latest in latest }
        )
        done = Set(
            jobStates
                .filter { $0.value == .done || $0.value == .failed || $0.value == .skipped }
                .keys
        )
    }
}
