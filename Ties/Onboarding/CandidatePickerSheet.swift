import SwiftUI
import TiesCore

/// The disambiguation sheet: every identity the research turned up for one person, with the
/// evidence behind each, so the user can say which one is actually them — or that none are.
///
/// Accepting one is what the store treats as the answer: it rejects the others by itself, so
/// this view only ever writes the single status it was asked to.
struct CandidatePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let person: Person
    /// Seeded by the caller so the sheet has rows to draw on its very first frame, then
    /// re-read from the store (with the evidence) as soon as it appears.
    @State private var candidates: [Candidate]
    @State private var evidence: [String: [Evidence]] = [:]
    @State private var errorMessage: String?

    let onChoose: (Candidate?) -> Void

    init(person: Person, candidates: [Candidate], onChoose: @escaping (Candidate?) -> Void) {
        self.person = person
        self._candidates = State(initialValue: candidates)
        self.onChoose = onChoose
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if candidates.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(candidates) { candidate in
                            row(candidate)
                            Divider()
                        }
                    }
                }
            }

            Divider()

            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(data: person.thumbnail, name: person.displayName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Which one is \(person.displayName)?")
                    .font(.headline)
                Text("Pick the profile that matches, or say none of them do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("None of these", action: rejectAll)
                .disabled(candidates.isEmpty)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func row(_ candidate: Candidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            avatar(candidate)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(candidate.displayName ?? person.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    ConfidencePill(score: candidate.score, status: candidate.status)
                    if let url = URL(string: candidate.primaryURL) {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .accessibilityLabel("Open profile")
                        .help(candidate.primaryURL)
                    }
                }

                if let headline = candidate.headline, !headline.isEmpty {
                    Text(headline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !place(candidate).isEmpty {
                    Text(place(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                let items = evidence[candidate.id] ?? []
                if !items.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(items.prefix(4)) { item in
                            EvidenceChip(evidence: item)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Button("Choose") { choose(candidate) }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Company and location on one line, whichever of them the candidate actually has.
    private func place(_ candidate: Candidate) -> String {
        [candidate.company, candidate.location]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The remote picture if there is one, falling back to the same initials placeholder the
    /// contact list draws while it loads — or for good if it never does.
    @ViewBuilder
    private func avatar(_ candidate: Candidate) -> some View {
        let placeholder = AvatarView(data: nil, name: candidate.displayName ?? person.displayName)
        if let url = candidate.avatarURL.flatMap({ URL(string: $0) }) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                placeholder
            }
            .frame(width: 40, height: 40)
            .clipShape(.circle)
            .accessibilityHidden(true)
        } else {
            placeholder
        }
    }

    // MARK: - Choosing

    private func load() {
        do {
            candidates = try model.store.candidates(personId: person.id)
            var byCandidate: [String: [Evidence]] = [:]
            for candidate in candidates {
                byCandidate[candidate.id] = try model.store
                    .evidence(candidateId: candidate.id)
                    .sorted(by: Self.strongestFirst)
            }
            evidence = byCandidate
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Conflicts first — a reason this might be the wrong person is the thing worth seeing, and
    /// a row only has room for four chips — then the heaviest evidence for the match.
    private static func strongestFirst(_ lhs: Evidence, _ rhs: Evidence) -> Bool {
        if (lhs.kind == .conflict) != (rhs.kind == .conflict) {
            return lhs.kind == .conflict
        }
        return lhs.weight > rhs.weight
    }

    private func choose(_ candidate: Candidate) {
        do {
            try model.store.setCandidateStatus(id: candidate.id, status: .accepted)
            onChoose(candidate)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rejectAll() {
        do {
            for candidate in candidates {
                try model.store.setCandidateStatus(id: candidate.id, status: .rejected)
            }
            onChoose(nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
