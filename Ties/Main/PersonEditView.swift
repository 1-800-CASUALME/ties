import SwiftUI
import TiesCore

/// Add or edit a person by hand. The same form does both: with no `person` it inserts a manual
/// one, with a `person` it updates them in place, including a researched contact whose facts the
/// user wants to correct.
///
/// Anything typed here is the user's own answer, so the profile it writes is attributed to
/// `"manual"` at full confidence — it was not guessed by a provider and should not be shown as
/// if it were.
///
/// A person who came from the address book is a partial exception. Their name, company, title
/// and channels are a mirror of a Contacts card: `upsertPeople` matches on `cnIdentifier` and
/// overwrites every one of those columns on the next sync, so an edit made here would be
/// reverted without a word the next time "Add more contacts…" is used. Those fields are shown
/// read-only for them, and only the profile — which Contacts knows nothing about — is written.
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
    /// True when the form couldn't be filled in from the store. Saving then would write a blank
    /// name and no channels over a person whose real details we simply failed to read.
    @State private var loadFailed = false

    /// The three profile fields as they were loaded. Save compares against them so editing only
    /// a phone number leaves a researched profile's `providerId` and confidence alone — the
    /// research wrote those, and correcting a typo in a phone number doesn't unwrite it.
    @State private var loadedOccupation = ""
    @State private var loadedSummary = ""
    @State private var loadedCanHelpWith = ""

    /// One editable contact row. Identified by a `UUID` of its own rather than by its value, so
    /// two blank rows (or two identical numbers) stay separate rows while being typed into.
    private struct ChannelRow: Identifiable {
        let id = UUID()
        var kind: Channel.Kind = .phone
        var label = ""
        var value = ""
    }

    /// Whether Contacts owns this person's name and channels — true for anyone synced from the
    /// address book, false for a manual person and for the new one this form adds.
    private var isManagedByContacts: Bool {
        person?.source == .contacts
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isManagedByContacts {
                    managedNameSection
                    managedContactSection
                } else {
                    nameSection
                    contactSection
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
                    .disabled(loadFailed)
            }
            .padding(16)
        }
        .frame(minWidth: 480, minHeight: 560)
        .onAppear(perform: load)
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section("Name") {
            TextField("First", text: $givenName)
            TextField("Last", text: $familyName)
            TextField("Company", text: $organization)
            TextField("Title", text: $jobTitle)
        }
    }

    private var contactSection: some View {
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
    }

    /// The Contacts mirror, shown rather than offered: the whole name as the card spells it,
    /// then only the parts that are filled in, so a card with no title doesn't grow an empty
    /// row that looks like something to type into.
    private var managedNameSection: some View {
        Section {
            LabeledContent("Name", value: person?.displayName ?? "")
            if !organization.isEmpty {
                LabeledContent("Company", value: organization)
            }
            if !jobTitle.isEmpty {
                LabeledContent("Title", value: jobTitle)
            }
        } header: {
            Text("Name")
        } footer: {
            Label("Imported from your contacts — the next sync overwrites these, so change them at the source", systemImage: "person.crop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var managedContactSection: some View {
        Section {
            if storedRows.isEmpty {
                Text("No phone, email, or website on this card.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(storedRows) { row in
                LabeledContent {
                    Text(row.value)
                        .textSelection(.enabled)
                } label: {
                    Label(row.label.isEmpty ? kindName(row.kind) : row.label, systemImage: symbol(row.kind))
                }
            }
        } header: {
            Text("Contact")
        } footer: {
            Text("The next sync with Contacts replaces these, so Ties doesn't edit them here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The channel rows that hold something. `load()` leaves one blank row behind for the
    /// editable form to type into; read-only, that row is nothing at all.
    private var storedRows: [ChannelRow] {
        rows.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func kindName(_ kind: Channel.Kind) -> String {
        switch kind {
        case .phone: "Phone"
        case .email: "Email"
        case .url: "Website"
        }
    }

    private func symbol(_ kind: Channel.Kind) -> String {
        switch kind {
        case .phone: "phone"
        case .email: "envelope"
        case .url: "link"
        }
    }

    private func placeholder(_ kind: Channel.Kind) -> String {
        switch kind {
        case .phone: "+1 555 010 0100"
        case .email: "name@example.com"
        case .url: "https://example.com"
        }
    }

    // MARK: - Loading

    /// Fills the form in. A read that fails says so and blocks Save rather than presenting a
    /// blank form that looks like a person with no details — saving that would be the one way
    /// to turn a transient read error into real data loss.
    private func load() {
        guard let person else {
            rows = [ChannelRow()]
            return
        }
        givenName = person.givenName
        familyName = person.familyName
        organization = person.organization ?? ""
        jobTitle = person.jobTitle ?? ""

        do {
            let stored = try model.store.channels(personId: person.id)
            rows = stored.map { ChannelRow(kind: $0.kind, label: $0.label ?? "", value: $0.value) }
            if rows.isEmpty { rows = [ChannelRow()] }

            let facts = try model.store.profile(personId: person.id)?.facts
            occupation = facts?.occupation ?? ""
            summary = facts?.summary ?? ""
            canHelpWith = (facts?.canHelpWith ?? []).joined(separator: ", ")
            loadedOccupation = occupation
            loadedSummary = summary
            loadedCanHelpWith = canHelpWith

            loadFailed = false
            errorMessage = nil
        } catch {
            loadFailed = true
            errorMessage = "Couldn't read \(person.displayName): \(error.localizedDescription)"
        }
    }

    // MARK: - Saving

    private func save() {
        guard !loadFailed else { return }

        // Contacts owns their name and their channels, and there is nothing on screen that
        // could have changed either; writing them back would only restamp `updatedAt` on a row
        // the next sync is going to rewrite anyway.
        if isManagedByContacts, let person {
            do {
                try saveProfile(for: person.id)
                onSave(person.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

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

    /// Whether the user actually touched any of the three profile fields this form owns.
    private var profileFieldsChanged: Bool {
        occupation != loadedOccupation
            || summary != loadedSummary
            || canHelpWith != loadedCanHelpWith
    }

    /// Writes the three profile fields this form owns, keeping whatever the research found in
    /// the ones it doesn't (companies, achievements, certificates, experience).
    ///
    /// Writes nothing at all unless one of those three was edited. Saving a form where only a
    /// phone number changed would otherwise restamp a researched profile as `"manual"` at full
    /// confidence, throwing away the provenance of facts the user never touched. A person with
    /// nothing typed and no profile already gets none written either: an empty profile would
    /// put them under "Researched" having never been researched.
    private func saveProfile(for personId: String) throws {
        guard profileFieldsChanged else { return }

        let existing = try model.store.profile(personId: personId)
        var facts = existing?.facts ?? .empty
        facts.occupation = trimmedOrNil(occupation)
        facts.summary = trimmedOrNil(summary)
        facts.canHelpWith = canHelpWith
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !facts.isEmpty || existing != nil else { return }

        try model.store.upsertProfile(
            Profile(
                personId: personId,
                facts: facts,
                confidence: 1,
                providerId: "manual",
                model: existing?.model,
                embedding: existing?.embedding
            )
        )
        reembed(personId: personId, facts: facts)
    }

    /// Re-embeds the edited facts so semantic search answers with this person too. Deliberately
    /// not awaited: embedding takes long enough to be felt, the profile is already saved and
    /// keyword-searchable without it, and the stale vector it replaces is no worse than none.
    ///
    /// Because it lands later, it re-reads the profile before writing and gives up if the facts
    /// have moved on — another edit, or an extraction that finished in between. It only ever
    /// changes `embedding`, so it can't undo whatever wrote the row it found.
    private func reembed(personId: String, facts: ProfileFacts) {
        let embedder = model.embedder
        let store = model.store
        Task.detached {
            guard let vector = try? await embedder.embed(facts.searchableText) else { return }
            guard var latest = try? store.profile(personId: personId), latest.facts == facts else { return }
            latest.embedding = vector
            try? store.upsertProfile(latest)
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
