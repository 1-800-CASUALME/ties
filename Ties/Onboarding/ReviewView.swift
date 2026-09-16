import SwiftUI
import TiesCore

/// Fifth screen of setup: what the research found, one row per person, with the three tools for
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
    @State private var errorMessage: String?

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

            // A re-run in flight is about to rewrite one of these rows; moving on mid-write
            // would extract from results the user never saw.
            PrimaryButton("Continue") { state.next() }
                .disabled(!rerunning.isEmpty)
                .padding(.vertical, 16)
        }
        .padding(.top, 24)
        .onAppear(perform: load)
        .onDisappear(perform: cancelReruns)
        .sheet(item: $picking) { person in
            CandidatePickerSheet(person: person, candidates: pickerCandidates) { _ in
                picking = nil
                load()
            }
        }
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

    private func load() {
        do {
            let selected = try model.store.allPeople().filter { state.selectedIds.contains($0.id) }
            people = selected
            best = try model.store.bestCandidatesByPerson()

            var counts: [String: Int] = [:]
            for person in selected {
                counts[person.id] = try model.store.candidates(personId: person.id).count
            }
            candidateCounts = counts

            // The default, and it applies whenever the selection is empty — not only on the
            // first load. This screen reloads after every pick and re-run, so a user who has
            // unchecked everyone gets the default back at the next reload; any selection with
            // something in it is left exactly as they left it.
            if state.selectedForExtract.isEmpty {
                state.selectedForExtract = Set(selected.map(\.id).filter { best[$0] != nil })
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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

    private func cancelReruns() {
        for task in rerunTasks.values { task.cancel() }
        rerunTasks = [:]
        rerunning = []
    }
}
