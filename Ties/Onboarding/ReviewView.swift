import SwiftUI
import TiesCore

/// Seventh screen of setup: what the research found, one row per person, with the three tools for
/// correcting it — see the sources it used, research that person again, or pick a different
/// identity — before anything is written up.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(WizardState.self) private var state

    @State private var people: [Person] = []
    @State private var best: [String: Candidate] = [:]
    /// How many identities the scan found per person; more than one earns the row a badge.
    @State private var candidateCounts: [String: Int] = [:]
    @State private var picking: Person?
    /// The rows the sheet opens with, read when the picker is asked for rather than inside the
    /// sheet's content builder — that closure runs on every redraw, and a store query there is a
    /// query every time SwiftUI feels like rebuilding.
    @State private var pickerCandidates: [Candidate] = []
    /// The row whose sources popover is open, if any.
    @State private var showingSourcesFor: String?
    @State private var rerunning: Set<String> = []
    /// The in-flight re-run per person, kept so leaving the screen can cancel them.
    @State private var rerunTasks: [String: Task<Void, Never>] = [:]
    /// What the Mac knows about each person locally, for the "Known as" chips (§6).
    @State private var signals: [String: LocalSignals] = [:]
    /// People whose best candidate was verified by a link they shared themselves.
    @State private var selfLinked: Set<String> = []
    /// The provider's verdict per person, as read from the store and as the judge produces it.
    @State private var judgements: [String: Judgement] = [:]
    /// People the scorer left in real doubt: two or more pending candidates, or one that didn't
    /// score convincingly. Only these are worth an AI call (§7.1).
    @State private var unsure: [String] = []
    @State private var judging = false
    @State private var judged = 0
    @State private var judgeTotal = 0
    @State private var judgeTask: Task<Void, Never>?
    /// So arriving here after the scan judges once, and coming back to the screen doesn't spend
    /// a second round of calls on the same people.
    @State private var judgeRequested = false
    /// The in-flight read of everything on this screen, so a pick can replace it rather than
    /// race it.
    @State private var loadTask: Task<Void, Never>?
    @State private var errorMessage: String?

    /// A lone pending candidate at or above this score is settled enough to leave alone — the
    /// same line `CandidateJudge` draws, kept here so the footer's count matches what it does.
    fileprivate static let confidentScore = 3.0

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            HStack {
                Text("Check what was found, then pick who to write up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Select All", isOn: allSelected)
                    .toggleStyle(.checkbox)
                    .disabled(people.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }

            if people.isEmpty {
                // Nobody has been researched — which arriving here by clicking the dot can
                // mean. Nothing to correct, and Continue still moves on.
                ContentUnavailableView {
                    Label("Nothing researched yet", systemImage: "magnifyingglass")
                } description: {
                    Text("Go back to Research to look people up, or carry on without it.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ContactListView(
                    people: people,
                    query: .constant(""),
                    selection: $state.selectedForExtract,
                    subtitle: { best[$0.id]?.headline ?? $0.organization }
                ) { person in
                    trailing(person)
                }
            }

            footer
        }
        .padding(.top, 24)
        .onAppear(perform: load)
        .onDisappear(perform: cancelWork)
        .sheet(item: $picking) { person in
            CandidatePickerSheet(person: person, candidates: pickerCandidates) { _ in
                picking = nil
                load()
            }
        }
    }

    // MARK: - Footer

    /// Continue, with the judge beside it: how far its pass has got, and the way to run it
    /// again on whoever is still uncertain.
    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            if judging {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Judging \(judged) of \(judgeTotal)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.quaternary))
                .transition(.opacity)
            }

            // A re-run in flight is about to rewrite one of these rows; moving on mid-write
            // would extract from results the user never saw.
            PrimaryButton("Continue") { state.next() }
                .disabled(!rerunning.isEmpty)

            judgeControl

            Spacer()
        }
        .padding(.vertical, 16)
        .animation(.snappy, value: judging)
        .animation(.snappy, value: unsure.count)
    }

    /// The judge's control, which is two different things depending on who would answer.
    ///
    /// On-device the pass has already run by itself, so this is the quiet `sparkle` that runs it
    /// again. With a cloud model nothing has run: the button says how many people it would ask
    /// about, because each of them is a billed call against the user's own key and §7 is explicit
    /// that nothing but the smart-list refresh happens without being asked for.
    @ViewBuilder
    private var judgeControl: some View {
        if autoJudges {
            Button { judgeUnsure(again: true) } label: {
                Image(systemName: "sparkle")
            }
            .buttonStyle(.borderless)
            .imageScale(.large)
            .disabled(judging || unsure.isEmpty)
            .help("Ask the AI which match is right")
            .accessibilityLabel("Judge again")
        } else if !unsure.isEmpty {
            Button { judgeUnsure(again: true) } label: {
                Label(
                    unsure.count == 1 ? "Judge 1 person" : "Judge \(unsure.count) people",
                    systemImage: "sparkle"
                )
            }
            .disabled(judging)
            .help("Ask the AI which match is right — one request per person")
        }
    }

    /// Whether the judge may run on its own. Only for a model that answers on this Mac: it costs
    /// nothing, sends nothing, and needs no permission beyond the one already given. Everything
    /// else waits for the button.
    private var autoJudges: Bool {
        model.selectedProviderId.flatMap(ProviderCatalog.spec)?.tier == .onDevice
    }

    private var allSelected: Binding<Bool> {
        Binding(
            get: { !people.isEmpty && state.selectedForExtract.count == people.count },
            set: { isOn in state.selectedForExtract = isOn ? Set(people.map(\.id)) : [] }
        )
    }

    // MARK: - Row trailing controls

    private func trailing(_ person: Person) -> some View {
        let candidate = best[person.id]
        let count = candidateCounts[person.id] ?? 0

        return HStack(spacing: 8) {
            KnownAsChips(signals: signals[person.id], hasSelfLink: selfLinked.contains(person.id), limit: 2)

            if let judgement = judgements[person.id] {
                SparkleChip(reason: judgement.reason)
                    .frame(maxWidth: 150, alignment: .trailing)
            }

            ConfidencePill(score: candidate?.score ?? 0, status: candidate?.status ?? .pending)

            if count > 1 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                    .help("\(count) possible matches")
                    .accessibilityLabel("\(count) possible matches")
            }

            Button { showingSourcesFor = person.id } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Sources")
            .help("Where this came from")
            .popover(isPresented: sourcesBinding(person.id)) { sources(person) }

            if rerunning.contains(person.id) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button { rerun(person) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Research again")
                .help("Research again")
            }

            Button { openPicker(for: person) } label: {
                Image(systemName: "person.crop.circle.badge.questionmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Pick a different match")
            .help("Pick a different match")
        }
    }

    private func sourcesBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { showingSourcesFor == id },
            set: { isOpen in showingSourcesFor = isOpen ? id : nil }
        )
    }

    /// The pages behind a person's profile: the ones belonging to the identity that was settled
    /// on, or, when nothing has been accepted or auto-matched yet, the best candidate's own.
    private func sourcePages(for person: Person) -> [SourcePage] {
        let accepted = (try? model.store.pagesForAccepted(personId: person.id)) ?? []
        if !accepted.isEmpty { return accepted }
        guard let candidate = best[person.id] else { return [] }
        return (try? model.store.pages(candidateId: candidate.id)) ?? []
    }

    private func sources(_ person: Person) -> some View {
        let pages = sourcePages(for: person)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if pages.isEmpty {
                    Text("No sources for \(person.displayName) yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pages) { page in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.title ?? host(page.url))
                                    .font(.callout)
                                    .lineLimit(1)
                                if let snippet = page.snippet, !snippet.isEmpty {
                                    Text(snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                            if let url = URL(string: page.url) {
                                Link(destination: url) {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .accessibilityLabel("Open \(host(page.url))")
                                .help(page.url)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 320, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host() ?? url
    }

    // MARK: - Loading and re-running

    /// Everything this screen draws, read in one pass off the main actor.
    ///
    /// The queries behind it are per-person — candidates, and the evidence behind the best one —
    /// so at a couple of thousand people they are thousands of round trips. Run where the window
    /// is drawn they are thousands of round trips *the window waits for*, on every arrival and
    /// after every pick; run here they are a background pass whose result lands in one
    /// assignment.
    private struct Snapshot: Sendable {
        var people: [Person] = []
        var best: [String: Candidate] = [:]
        var candidateCounts: [String: Int] = [:]
        var selfLinked: Set<String> = []
        var unsure: [String] = []
        var signals: [String: LocalSignals] = [:]
        var judgements: [String: Judgement] = [:]
        var failure: String?

        /// Reads the lot. Nothing here touches the view — it is handed a `Store` (which is
        /// `Sendable`) and the ids to care about, and gives back plain values.
        init(store: Store, selected: Set<String>) {
            do {
                people = try store.allPeople().filter { selected.contains($0.id) }
                best = try store.bestCandidatesByPerson()
                signals = try store.signalsByPerson()
                judgements = try store.judgementsByPerson()

                for person in people {
                    let candidates = try store.candidates(personId: person.id)
                    candidateCounts[person.id] = candidates.count

                    if let best = best[person.id],
                       try store.evidence(candidateId: best.id).contains(where: { $0.kind == .selfLink }) {
                        selfLinked.insert(person.id)
                    }

                    // The same test `CandidateJudge` applies, run here so the footer can count
                    // the people it would ask about before anything is asked.
                    guard !candidates.contains(where: { $0.status == .accepted }) else { continue }
                    let pending = candidates.filter { $0.status == .pending }
                    let top = pending.map(\.score).max() ?? 0
                    if pending.count >= 2 || (pending.count == 1 && top < ReviewView.confidentScore) {
                        unsure.append(person.id)
                    }
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Reads everything again, in the background. A load already in flight is dropped: it
    /// describes the store as it was before the pick or the re-run that asked for this one.
    private func load() {
        loadTask?.cancel()
        let store = model.store
        let selected = state.selectedIds
        loadTask = model.track {
            let snapshot = await Task.detached { Snapshot(store: store, selected: selected) }.value
            guard !Task.isCancelled else { return }
            apply(snapshot)
        }
    }

    private func apply(_ snapshot: Snapshot) {
        people = snapshot.people
        best = snapshot.best
        candidateCounts = snapshot.candidateCounts
        selfLinked = snapshot.selfLinked
        unsure = snapshot.unsure
        signals = snapshot.signals
        // A verdict that landed while this load was in flight is newer than the row it read.
        judgements = snapshot.judgements.merging(judgements) { _, newer in newer }
        errorMessage = snapshot.failure

        // The default, and it applies whenever the selection is empty — not only on the first
        // load. This screen reloads after every pick and re-run, so a user who has unchecked
        // everyone gets the default back at the next reload; any selection with something in it
        // is left exactly as they left it.
        if state.selectedForExtract.isEmpty {
            state.selectedForExtract = Set(people.map(\.id).filter { best[$0] != nil })
        }

        // Judging waits for the rows: `unsure` is what it works from, and on-device it starts
        // the moment there is something to work on.
        if autoJudges { judgeUnsure() }
    }

    private func openPicker(for person: Person) {
        pickerCandidates = (try? model.store.candidates(personId: person.id)) ?? []
        picking = person
    }

    /// Researches one person again with a scanner of their own, so it can't collide with the
    /// wizard's run, which has long since finished by the time this screen is up. The task is
    /// kept so leaving the screen stops waiting on it.
    private func rerun(_ person: Person) {
        let personId = person.id
        guard rerunTasks[personId] == nil else { return }
        rerunning.insert(personId)
        let scanner = model.makeScanner()
        rerunTasks[personId] = Task {
            for await _ in await scanner.run(personIds: [personId]) {}
            rerunTasks[personId] = nil
            rerunning.remove(personId)
            guard !Task.isCancelled else { return }
            load()
        }
    }

    private func cancelWork() {
        loadTask?.cancel()
        loadTask = nil
        for task in rerunTasks.values { task.cancel() }
        rerunTasks = [:]
        rerunning = []
        judgeTask?.cancel()
        judgeTask = nil
        judging = false
    }

    // MARK: - The judge

    /// Asks the provider about the people the scorer couldn't settle (§7.1), one at a time so
    /// the footer can count them, and writes each verdict to the store as it lands — the chip
    /// then survives leaving this screen and coming back.
    ///
    /// Nothing is accepted on the model's say-so: a verdict only puts a `sparkle` chip on the
    /// row, and the user still picks. A person who already has a verdict is skipped unless the
    /// button asked for another round, and a provider that can't be built means no judging at
    /// all — this is an aid to the review, not a step in it.
    ///
    /// It runs by itself only for a model on this Mac (`autoJudges`). A cloud provider is one
    /// billed request per uncertain person — several hundred after a large research run — so
    /// there the pass waits behind a button that says how many that is.
    private func judgeUnsure(again: Bool = false) {
        guard !judging else { return }
        // The automatic pass runs once per visit to this screen; the button is how to ask for
        // another one.
        guard again || !judgeRequested else { return }

        let ids = unsure.filter { again || judgements[$0] == nil }
        // Nothing was asked of the provider if there is nobody to ask about or no provider to
        // ask, so the visit's one automatic pass is still unspent: a screen that arrives before
        // its rows are loaded must be able to try again.
        guard !ids.isEmpty, let judge = try? model.makeJudge() else { return }
        judgeRequested = true

        judging = true
        judged = 0
        judgeTotal = ids.count
        // The same bookkeeping the scan and the extraction keep (§9): a `judge` job per person,
        // so what this pass did is readable from the store afterwards rather than only from the
        // view that ran it.
        try? model.store.enqueue(kind: .judge, personIds: ids)
        judgeTask = model.track {
            for id in ids {
                guard !Task.isCancelled else { break }
                try? model.store.setJob(kind: .judge, personId: id, state: .running)
                do {
                    // A person the judge decides isn't worth asking about — the scorer settled
                    // it after all — is skipped rather than failed: nothing went wrong.
                    if let verdict = try await judge.judge(personId: id) {
                        try model.store.upsertJudgement(verdict)
                        judgements[id] = verdict
                        try? model.store.setJob(kind: .judge, personId: id, state: .done)
                    } else {
                        try? model.store.setJob(kind: .judge, personId: id, state: .skipped)
                    }
                } catch {
                    // A verdict that fails — a model that named a candidate nobody offered, a
                    // provider that timed out — costs that one row its chip, not the pass.
                    try? model.store.setJob(kind: .judge, personId: id, state: .failed, error: error.localizedDescription)
                }
                judged += 1
            }
            judging = false
            judgeTask = nil
        }
    }
}
