import SwiftUI
import TiesCore

/// Add or edit a person by hand. The same form does both: with no `person` it inserts a manual
/// one, with a `person` it updates them in place, including a researched contact whose facts the
/// user wants to correct.
///
/// Anything typed here is the user's own answer, so the profile it writes is attributed to
/// `"manual"` at full confidence — it was not guessed by a provider and should not be shown as
/// if it were.
struct PersonEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The person being edited, or `nil` when adding a new one.
    let person: Person?
    /// Called with the saved person's id once the write has gone through, so the window that
    /// presented the sheet can reload and select them.
    let onSave: (String) -> Void

    @State private var givenName = ""
    @State private var familyName = ""
    @State private var organization = ""
    @State private var jobTitle = ""
    @State private var rows: [ChannelRow] = []
    @State private var occupation = ""
    @State private var summary = ""
    @State private var canHelpWith = ""
    @State private var errorMessage: String?

    /// One editable contact row. Identified by a `UUID` of its own rather than by its value, so
    /// two blank rows (or two identical numbers) stay separate rows while being typed into.
    private struct ChannelRow: Identifiable {
        let id = UUID()
        var kind: Channel.Kind = .phone
        var label = ""
        var value = ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Name") {
                    TextField("First", text: $givenName)
                    TextField("Last", text: $familyName)
                    TextField("Company", text: $organization)
                    TextField("Title", text: $jobTitle)
                }

                Section("Contact") {
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            Picker("Kind", selection: $row.kind) {
                                Text("Phone").tag(Channel.Kind.phone)
                                Text("Email").tag(Channel.Kind.email)
                                Text("URL").tag(Channel.Kind.url)
                            }
                            .labelsHidden()
                            .frame(width: 90)

                            TextField("Label", text: $row.label)
                                .frame(width: 80)

                            TextField(placeholder(row.kind), text: $row.value)

                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove")
                        }
                    }

                    Button {
                        rows.append(ChannelRow())
                    } label: {
                        Label("Add", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }

                Section {
                    TextField("Occupation", text: $occupation)
                    TextField("Summary", text: $summary, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Can help with", text: $canHelpWith)
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Separate the topics they can help with by commas. They are searched the same way researched ones are.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear(perform: load)
    }

    private func placeholder(_ kind: Channel.Kind) -> String {
        switch kind {
        case .phone: "+1 555 010 0100"
        case .email: "name@example.com"
        case .url: "https://example.com"
        }
    }

    // MARK: - Loading

    private func load() {
        guard let person else {
            rows = [ChannelRow()]
            return
        }
        givenName = person.givenName
        familyName = person.familyName
        organization = person.organization ?? ""
        jobTitle = person.jobTitle ?? ""

        let stored = (try? model.store.channels(personId: person.id)) ?? []
        rows = stored.map { ChannelRow(kind: $0.kind, label: $0.label ?? "", value: $0.value) }
        if rows.isEmpty { rows = [ChannelRow()] }

        let facts = (try? model.store.profile(personId: person.id))?.facts
        occupation = facts?.occupation ?? ""
        summary = facts?.summary ?? ""
        canHelpWith = (facts?.canHelpWith ?? []).joined(separator: ", ")
    }

    // MARK: - Saving

    private func save() {
        let given = givenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let family = familyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !given.isEmpty || !family.isEmpty else {
            errorMessage = "Enter a first or last name."
            return
        }

        var subject = person ?? Person(givenName: given, familyName: family, source: .manual)
        subject.givenName = given
        subject.familyName = family
        subject.displayName = "\(given) \(family)".trimmingCharacters(in: .whitespaces)
        subject.organization = trimmedOrNil(organization)
        subject.jobTitle = trimmedOrNil(jobTitle)
        subject.updatedAt = .now

        let channels = rows.compactMap { row -> Channel? in
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return Channel(
                personId: subject.id,
                kind: row.kind,
                label: trimmedOrNil(row.label),
                value: value,
                normalized: normalize(value, kind: row.kind)
            )
        }

        do {
            if person == nil {
                try model.store.insertManualPerson(subject, channels: channels)
            } else {
                try model.store.updatePerson(subject, channels: channels)
            }
            try saveProfile(for: subject.id)
            onSave(subject.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes the three profile fields this form owns, keeping whatever the research found in
    /// the ones it doesn't (companies, achievements, certificates, experience).
    ///
    /// A person with nothing typed in any of them and no profile already gets none written: an
    /// empty profile would put them under "Researched" having never been researched.
    private func saveProfile(for personId: String) throws {
        let existing = try model.store.profile(personId: personId)
        var facts = existing?.facts ?? .empty
        facts.occupation = trimmedOrNil(occupation)
        facts.summary = trimmedOrNil(summary)
        facts.canHelpWith = canHelpWith
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !facts.isEmpty || existing != nil else { return }

        let profile = Profile(
            personId: personId,
            facts: facts,
            confidence: 1,
            providerId: "manual",
            model: existing?.model,
            embedding: existing?.embedding
        )
        try model.store.upsertProfile(profile)
        reembed(profile)
    }

    /// Re-embeds the edited facts so semantic search answers with this person too. Deliberately
    /// not awaited: embedding takes long enough to be felt, the profile is already saved and
    /// keyword-searchable without it, and the stale vector it replaces is no worse than none.
    private func reembed(_ profile: Profile) {
        let embedder = model.embedder
        let store = model.store
        Task {
            guard let vector = try? await embedder.embed(profile.facts.searchableText) else { return }
            var updated = profile
            updated.embedding = vector
            try? store.upsertProfile(updated)
        }
    }

    private func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The same normalization `ContactSync` applies to imported contacts, so a hand-typed number
    /// is findable by the same digit search as one from the address book.
    private func normalize(_ value: String, kind: Channel.Kind) -> String {
        switch kind {
        case .phone:
            let region = Locale.current.region?.identifier ?? "US"
            if let e164 = PhoneNormalizer.e164(value, defaultRegion: region) { return e164 }
            let digits = PhoneNormalizer.digits(value)
            return value.hasPrefix("+") ? "+" + digits : digits
        case .email:
            return value.lowercased()
        case .url:
            var normalized = value.lowercased()
            if normalized.hasSuffix("/") { normalized.removeLast() }
            return normalized
        }
    }
}
