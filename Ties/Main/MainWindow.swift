import SwiftUI
import TiesCore

/// The app proper, once setup is done: lists on the left, people in the middle, one person on
/// the right.
///
/// It owns the three tables every column reads — people, their profiles, and the best candidate
/// found for each — because the sidebar filters on all three and the list column shows two of
/// them. Anything that changes a person calls back into `load()` rather than editing these
/// copies, so one read is the whole truth on screen.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    @State private var sidebar: SidebarItem? = .all
    @State private var selectedId: String?
    @State private var people: [Person] = []
    @State private var profiles: [String: Profile] = [:]
    @State private var best: [String: Candidate] = [:]
    /// What the Mac knows about each person locally, which is what Reconnect is ranked on.
    @State private var signals: [String: LocalSignals] = [:]
    @State private var adding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar)
        } content: {
            PeopleListView(
                people: listed,
                profiles: profiles,
                best: best,
                selectedId: $selectedId,
                onAdd: { adding = true }
            )
            .navigationTitle(title)
            .navigationSubtitle("\(listed.count) people")
        } detail: {
            detail
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .onAppear(perform: load)
        .onChange(of: selectedId) { _, id in model.selectedPersonId = id }
        .onChange(of: model.newPersonRequest) { adding = true }
        .sheet(isPresented: $adding) {
            PersonEditView(person: nil) { newPerson in
                load()
                selectedId = newPerson
            }
        }
        .overlay(alignment: .top) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
            }
        }
    }

    // MARK: - Columns

    @ViewBuilder
    private var detail: some View {
        if let person = selectedPerson {
            PersonDetailView(person: person, onChanged: load)
                // A different person is a different screen's worth of state — note, profile,
                // an in-flight refresh — not the same screen with new values in it.
                .id(person.id)
        } else if people.isEmpty {
            // Nobody in the database at all, which is what skipping setup leaves behind. The
            // way back into setup belongs here, where the emptiness is.
            ContentUnavailableView {
                Label("Nobody here yet", systemImage: "person.2")
            } description: {
                Text("Setup imports your contacts and researches the people you pick. You can also add someone by hand.")
            } actions: {
                Button("Set up Ties…", action: startSetup)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else {
            ContentUnavailableView("Select a person", systemImage: "person.crop.circle")
        }
    }

    /// Back into the wizard, from the beginning: there is nothing in the database for it to
    /// resume alongside.
    ///
    /// `.welcome` rather than `nil`, which is the same first screen but leaves the way out:
    /// there is an app behind this wizard to go back to, and `WizardWindow` takes a set
    /// resume step as its cue to offer Cancel.
    private func startSetup() {
        model.resumeWizardStep = .welcome
        model.hasCompletedSetup = false
    }

    private var selectedPerson: Person? {
        guard let selectedId else { return nil }
        return people.first { $0.id == selectedId }
    }

    private var title: String {
        switch sidebar ?? .all {
        case .all: "All"
        case .researched: "Researched"
        case .unsure: "Unsure"
        case .manual: "Manual"
        case .reconnect: "Reconnect"
        case .smartList(let id): smartList(id)?.name ?? "Smart list"
        }
    }

    private func smartList(_ id: String) -> SmartList? {
        model.smartLists.first { $0.id == id }
    }

    /// The people the chosen list is about. "Unsure" is the one worth spelling out: it means the
    /// research found someone but wasn't sure enough to settle on them, which is exactly the set
    /// the candidate picker exists for — not everyone who hasn't been researched at all.
    private var listed: [Person] {
        switch sidebar ?? .all {
        case .all:
            people
        case .researched:
            people.filter { profiles[$0.id] != nil }
        case .unsure:
            people.filter { best[$0.id]?.status == .pending }
        case .manual:
            people.filter { $0.source == .manual }
        case .reconnect:
            reconnect
        case .smartList(let id):
            members(of: id)
        }
    }

    /// People worth getting back to: someone the research wrote up, last talked to more than
    /// three months ago, strongest relationship first (§4.5). Somebody with no signals at all
    /// isn't here — nothing on this Mac says the two of you have ever talked, so nothing says
    /// you have stopped.
    private var reconnect: [Person] {
        let cutoff = Date.now.addingTimeInterval(-90 * 24 * 60 * 60)
        return people
            .filter { person in
                guard profiles[person.id] != nil, let last = signals[person.id]?.lastContact else { return false }
                return last < cutoff
            }
            .sorted { lhs, rhs in
                let left = signals[lhs.id]?.interactions ?? 0
                let right = signals[rhs.id]?.interactions ?? 0
                // Equal strength falls back to the name, so the list doesn't reshuffle itself
                // between reloads.
                return left == right ? lhs.displayName < rhs.displayName : left > right
            }
    }

    /// The people in one smart list, in the order the provider grouped them. Ids it named that
    /// have since been deleted simply drop out.
    private func members(of id: String) -> [Person] {
        guard let list = smartList(id) else { return [] }
        let byId = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return list.personIds.compactMap { byId[$0] }
    }

    // MARK: - Loading

    private func load() {
        do {
            people = try model.store.allPeople()
            profiles = try model.store.profilesByPerson()
            best = try model.store.bestCandidatesByPerson()
            signals = try model.store.signalsByPerson()
            model.loadSmartLists()
            if let selectedId, !people.contains(where: { $0.id == selectedId }) {
                self.selectedId = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
