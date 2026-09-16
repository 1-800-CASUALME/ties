import SwiftUI
import TiesCore

/// The middle column, and the one search field the whole app has.
///
/// The same field does two jobs. Typing narrows the contact list as you go — name, company, or
/// phone digits — which is what a search box in a contacts app is expected to do. Pressing
/// Return, or opening with `?`, turns the same text into a "who do I know that can help with
/// this" question and replaces the list with ranked answers. Clearing the field (or pressing
/// Escape, which clears it) puts the contact list back.
struct PeopleListView: View {
    @Environment(AppModel.self) private var model

    let people: [Person]
    let profiles: [String: Profile]
    let best: [String: Candidate]
    @Binding var selectedId: String?
    let onAdd: () -> Void

    @State private var query = ""
    /// Set by Return, cleared by editing or clearing the field. Together with a leading `?` it
    /// is what puts the column into ask mode.
    @State private var submitted = false
    @State private var results: [SearchResult] = []
    @State private var searching = false
    /// The in-flight `ask`, held so each new query can cancel the last rather than racing it.
    @State private var askTask: Task<Void, Never>?
    /// Bumped by every query. A run that comes back to find the number has moved on is a run
    /// nobody is waiting for any more, and must not touch the results or the spinner —
    /// cancellation alone doesn't cover it, because a run that has already finished its `ask`
    /// can't be cancelled out of writing what it found.
    @State private var askGeneration = 0
    @State private var errorMessage: String?

    private enum Mode {
        case filter, ask
    }

    private var mode: Mode {
        query.hasPrefix("?") || submitted ? .ask : .filter
    }

    var body: some View {
        Group {
            switch mode {
            case .filter: filterList
            case .ask: askList
            }
        }
        .animation(.snappy, value: results)
        .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        .searchable(text: $query, placement: .toolbar, prompt: "Search or ask…")
        .onSubmit(of: .search) { runAsk(debounced: false) }
        .onChange(of: query) { _, text in queryChanged(text) }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    // MARK: - Filter mode

    private var filterList: some View {
        ContactListView(
            people: people,
            query: $query,
            activeId: $selectedId,
            subtitle: subtitle
        ) { person in
            if let candidate = best[person.id] {
                ConfidencePill(score: candidate.score, status: candidate.status)
            }
        }
    }

    /// What the research thinks this person does, falling back to whatever Contacts said.
    private func subtitle(_ person: Person) -> String? {
        let occupation = profiles[person.id]?.facts.occupation
        if let occupation, !occupation.isEmpty { return occupation }
        return person.jobTitle ?? person.organization
    }

    // MARK: - Ask mode

    @ViewBuilder
    private var askList: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Search failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else if results.isEmpty && !searching {
            ContentUnavailableView.search
        } else {
            List(selection: $selectedId) {
                ForEach(results, id: \.personId) { result in
                    askRow(result)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func askRow(_ result: SearchResult) -> some View {
        let person = people.first { $0.id == result.personId }

        return HStack(spacing: 10) {
            AvatarView(data: person?.thumbnail, name: person?.displayName ?? "?", size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(person?.displayName ?? result.personId)
                    .font(.body)
                if !result.why.isEmpty {
                    Text(highlighted(result.why))
                        .font(.caption)
                        .lineLimit(2)
                }
                ProgressView(value: share(of: result.score))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// A result's score as a fraction of the best one in this answer. Reciprocal rank fusion
    /// produces small absolute numbers (around 1/60 per list a person appears in) that mean
    /// nothing on their own, so the bar compares within the answer rather than to any scale.
    private func share(of score: Double) -> Double {
        guard let top = results.map(\.score).max(), top > 0 else { return 0 }
        return min(max(score / top, 0), 1)
    }

    /// The `why` line with the words the user actually searched for picked out, so it is
    /// obvious at a glance which part of the profile earned the match.
    private func highlighted(_ why: String) -> AttributedString {
        var attributed = AttributedString(why)
        for token in tokens {
            var cursor = attributed.startIndex
            while cursor < attributed.endIndex,
                  let range = attributed[cursor..<attributed.endIndex].range(of: token, options: .caseInsensitive) {
                attributed[range].font = .caption.bold()
                attributed[range].foregroundColor = .accentColor
                cursor = range.upperBound
            }
        }
        return attributed
    }

    /// Words from the query worth highlighting: the short connective ones match everywhere and
    /// would turn the whole line blue.
    private var tokens: [String] {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("?") { text.removeFirst() }
        return text
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { $0.count >= 3 && !Self.stopWords.contains($0.lowercased()) }
    }

    private static let stopWords: Set<String> = [
        "who", "can", "help", "with", "the", "and", "for", "that", "someone", "know", "does",
    ]

    // MARK: - Running the query

    private func queryChanged(_ text: String) {
        if text.hasPrefix("?") {
            runAsk(debounced: true)
            return
        }
        // Back to filtering: drop the answer and the run that was producing it.
        askTask?.cancel()
        askTask = nil
        askGeneration += 1
        searching = false
        submitted = false
        results = []
        errorMessage = nil
    }

    /// Answers the current query. Typing past a `?` waits out a pause first — every keystroke
    /// would otherwise start a fused keyword-and-embedding search over the whole store, and the
    /// answer to half a word is worth nothing. Return means the user has finished typing and
    /// runs immediately.
    private func runAsk(debounced: Bool) {
        askTask?.cancel()
        askGeneration += 1
        let generation = askGeneration

        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("?") { trimmed.removeFirst() }
        let text = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            askTask = nil
            searching = false
            results = []
            errorMessage = nil
            return
        }

        submitted = true
        searching = true
        errorMessage = nil
        let search = model.search
        askTask = model.track {
            if debounced {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, generation == askGeneration else { return }
            }
            do {
                let hits = try await search.ask(text, limit: 50)
                guard !Task.isCancelled, generation == askGeneration else { return }
                results = hits
                errorMessage = nil
            } catch {
                guard !Task.isCancelled, generation == askGeneration else { return }
                results = []
                errorMessage = error.localizedDescription
            }
            // Only the newest run owns the spinner; an older one turning it off would hide a
            // search that is still going.
            if generation == askGeneration { searching = false }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Person")
            .accessibilityLabel("New Person")

            Spacer()

            if searching {
                ProgressView()
                    .controlSize(.small)
            } else if mode == .ask, !results.isEmpty {
                Text("\(results.count) matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
