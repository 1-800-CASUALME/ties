import SwiftUI
import TiesCore

/// Everything Ties knows about one person, and everything it can do with them.
///
/// The view reads its own rows rather than being handed them: the note, the channels, and the
/// profile all change from inside this screen (editing, refreshing, typing a note), and reading
/// them here keeps one reload path for all of it. `onChanged` tells the main window when
/// something it also shows — a name, a new profile — has moved underneath it.
struct PersonDetailView: View {
    @Environment(AppModel.self) private var model

    let person: Person
    let onChanged: () -> Void

    @State private var channels: [Channel] = []
    @State private var profile: Profile?
    @State private var best: Candidate?
    @State private var sources: [SourcePage] = []
    /// What this Mac knows about them locally: the names they go by, and the relationship.
    @State private var signals: LocalSignals?
    /// Whether the identity settled on was verified by a link they shared themselves.
    @State private var selfLinked = false
    @State private var drafting = false

    @State private var note = ""
    /// The note as the store last had it, so loading one doesn't look like the user typing it.
    @State private var savedNote = ""
    @State private var noteTask: Task<Void, Never>?

    @State private var editing = false
    @State private var picking: Person?

    @State private var refreshing = false
    @State private var progress: ScanProgress?
    @State private var refreshTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionPills
                contactsSection
                researchedSection
                yoursSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear(perform: load)
        // Leaving is the last chance to keep what was typed: the debounce hasn't fired yet, and
        // this view is rebuilt per person (`.id`), so cancelling it without writing would throw
        // the note away on every switch, window close and quit.
        .onDisappear {
            flushNote(personId: person.id)
            cancelRefresh()
        }
        // Belt and braces for a caller that stops keying this view by person: the same flush,
        // to the person whose note is actually in the editor.
        .onChange(of: person.id) { previousId, _ in
            flushNote(personId: previousId)
            cancelRefresh()
            load()
        }
        .onChange(of: model.refreshRequest) { refresh() }
        .sheet(isPresented: $editing) {
            PersonEditView(person: person) { _ in
                load()
                onChanged()
            }
        }
        .sheet(item: $picking) { subject in
            CandidatePickerSheet(
                person: subject,
                candidates: (try? model.store.candidates(personId: subject.id)) ?? []
            ) { _ in
                picking = nil
                load()
                onChanged()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AvatarView(data: person.thumbnail, name: person.displayName, size: 96)

            VStack(alignment: .leading, spacing: 6) {
                Text(person.displayName)
                    .font(.title.bold())
                    .textSelection(.enabled)

                if !headline.isEmpty {
                    Text(headline)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                KnownAsChips(signals: signals, hasSelfLink: selfLinked)

                if let signals, signals.lastContact != nil || signals.interactions > 0 {
                    RelationshipRow(signals: signals)
                }

                HStack(spacing: 8) {
                    if let best {
                        ConfidencePill(score: best.score, status: best.status)
                    }
                    if !sourceNames.isEmpty {
                        Text("Sources: \(sourceNames)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            Button { picking = person } label: {
                Image(systemName: "person.crop.circle.badge.questionmark")
            }
            .buttonStyle(.borderless)
            .imageScale(.large)
            .help("Pick a different match")
            .accessibilityLabel("Pick a different match")
        }
    }

    /// Occupation and company on one line, using whichever of them this person actually has.
    private var headline: String {
        let occupation = profile?.facts.occupation ?? person.jobTitle
        let company = profile?.facts.companies.first?.text ?? person.organization
        return [occupation, company]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The sites the research actually read, named the way a person would say them.
    private var sourceNames: String {
        var seen: [String] = []
        for page in sources {
            guard let host = URL(string: page.url)?.host() else { continue }
            let name = Self.siteName(host)
            if !name.isEmpty, !seen.contains(name) { seen.append(name) }
        }
        return seen.prefix(4).joined(separator: ", ")
    }

    /// `www.linkedin.com` → `LinkedIn`: the second-level label, capitalized, with the handful of
    /// brands whose own spelling isn't a plain capitalization written out.
    private static func siteName(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host.capitalized }
        let name = labels[labels.count - 2]
        switch name {
        case "linkedin": return "LinkedIn"
        case "github": return "GitHub"
        case "youtube": return "YouTube"
        default: return name.capitalized
        }
    }

    // MARK: - Actions

    private var actionPills: some View {
        HStack(spacing: 10) {
            pill("Message", symbol: "message", over: phones, action: Actions.message)
            pill("Call", symbol: "phone", over: phones, action: Actions.call)
            pill("FaceTime", symbol: "video", over: phones + emails, action: Actions.facetime)
            pill("Mail", symbol: "envelope", over: emails, action: Actions.mail)

            Button { drafting = true } label: {
                Label("Draft", systemImage: "sparkle.bubble")
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            .help("Draft a message to \(person.displayName)")
            .popover(isPresented: $drafting, arrowEdge: .bottom) {
                DraftPopover(person: person, facts: profile?.facts, channels: channels)
            }

            ShareLink(item: vCard, preview: SharePreview(person.displayName)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())

            Spacer(minLength: 0)
        }
    }

    /// One action pill. Clicking uses the first number or address; Control-clicking offers all
    /// of them, which is the only way to reach a second number without leaving the app.
    private func pill(
        _ title: String,
        symbol: String,
        over options: [Channel],
        action: @escaping (String) -> Void
    ) -> some View {
        Button {
            if let first = options.first { action(first.value) }
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .clipShape(Capsule())
        .disabled(options.isEmpty)
        .help(options.isEmpty ? "No \(title.lowercased()) details for \(person.displayName)" : title)
        .contextMenu {
            ForEach(options.indices, id: \.self) { index in
                let channel = options[index]
                Button(menuTitle(channel)) { action(channel.value) }
            }
        }
    }

    private func menuTitle(_ channel: Channel) -> String {
        guard let label = channel.label, !label.isEmpty else { return channel.value }
        return "\(label): \(channel.value)"
    }

    private var phones: [Channel] { channels.filter { $0.kind == .phone } }
    private var emails: [Channel] { channels.filter { $0.kind == .email } }

    private var vCard: VCardFile {
        Actions.vCardItem(person: person, channels: channels, facts: profile?.facts)
    }

    // MARK: - Contacts

    private var contactsSection: some View {
        GroupBox("Contacts") {
            VStack(alignment: .leading, spacing: 6) {
                if channels.isEmpty {
                    Text("No phone numbers or addresses.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(channels.indices, id: \.self) { index in
                        let channel = channels[index]
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(channel.label ?? defaultLabel(channel.kind))
                                .foregroundStyle(.secondary)
                                .frame(width: 90, alignment: .leading)
                            if let url = link(for: channel) {
                                Link(channel.value, destination: url)
                            } else {
                                Text(channel.value)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func defaultLabel(_ kind: Channel.Kind) -> String {
        switch kind {
        case .phone: "phone"
        case .email: "email"
        case .url: "url"
        }
    }

    private func link(for channel: Channel) -> URL? {
        switch channel.kind {
        case .phone: URL(string: "tel:" + channel.value.filter { $0.isNumber || $0 == "+" })
        case .email: URL(string: "mailto:" + channel.value.trimmingCharacters(in: .whitespaces))
        case .url: URL(string: channel.value.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Researched

    @ViewBuilder
    private var researchedSection: some View {
        if let facts = profile?.facts, !facts.isEmpty {
            GroupBox("Researched") {
                VStack(alignment: .leading, spacing: 12) {
                    if !facts.canHelpWith.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(facts.canHelpWith, id: \.self) { topic in
                                Text(topic)
                                    .font(.caption)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(.tint.opacity(0.15)))
                            }
                        }
                    }

                    if let summary = facts.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    factGroup("Work", facts.companies)
                    factGroup("Education & Certificates", facts.certificates)
                    factGroup("Achievements", facts.achievements)
                    factGroup("Experience", facts.experience)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func factGroup(_ title: String, _ facts: [Fact]) -> some View {
        if !facts.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(facts.indices, id: \.self) { index in
                        let fact = facts[index]
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // A fact the second pass couldn't find in the pages it cites is
                            // shown, not hidden — with a dotted underline and a reason (§7.6).
                            Text(fact.text)
                                .underline(fact.supported == false, pattern: .dot)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            if fact.supported == false {
                                Image(systemName: "questionmark.circle")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                                    .help("Not found in the sources")
                                    .accessibilityLabel("Not found in the sources")
                            }
                            if let url = fact.sources.first.flatMap({ URL(string: $0) }) {
                                Link(destination: url) {
                                    Image(systemName: "link")
                                        .imageScale(.small)
                                }
                                .help(url.absoluteString)
                                .accessibilityLabel("Open source")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(title)
                    .font(.callout.weight(.medium))
            }
        }
    }

    // MARK: - Yours

    private var yoursSection: some View {
        GroupBox("Yours") {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $note)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                    .accessibilityLabel("Notes about \(person.displayName)")
                Text("Your own notes. Saved as you type, and searched along with the research.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .onChange(of: note) { _, text in scheduleNoteSave(text) }
    }

    /// Writes the note half a second after the last keystroke. A `TextEditor` fires on every
    /// character and the note lives in the same table the search index is rebuilt from, so
    /// saving each one would rewrite the FTS row dozens of times per sentence.
    ///
    /// A debounce that only ever waits can also never save: someone who types without pausing
    /// and then closes the window keeps restarting the timer. `flushNote` is the answer to
    /// that, and every way out of this screen goes through it.
    private func scheduleNoteSave(_ text: String) {
        guard text != savedNote else { return }
        noteTask?.cancel()
        let personId = person.id
        noteTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            writeNote(text, personId: personId)
        }
    }

    /// Writes a pending note right now and drops the debounce that was going to. Synchronous on
    /// purpose: the callers are leaving — the view is disappearing, or is about to be reloaded
    /// out from under the editor — and there is no later for an async write to happen in.
    private func flushNote(personId: String) {
        noteTask?.cancel()
        noteTask = nil
        guard note != savedNote else { return }
        writeNote(note, personId: personId)
    }

    private func writeNote(_ text: String, personId: String) {
        do {
            try model.store.upsertNote(Note(personId: personId, body: text))
            savedNote = text
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if refreshing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.quaternary))
            }

            Button("Refresh", action: refresh)
                .disabled(refreshing)
            Button("Edit") { editing = true }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var progressCaption: String {
        if let waitingFor = progress?.waitingFor { return "Waiting for \(waitingFor)…" }
        return "Researching \(person.displayName)…"
    }

    // MARK: - Loading and refreshing

    /// Re-reads everything this screen shows. Anything still in the note editor is written
    /// first: a reload triggered by a refresh or an edit would otherwise replace unsaved text
    /// with the older copy the store still has.
    private func load() {
        flushNote(personId: person.id)
        do {
            channels = try model.store.channels(personId: person.id)
            profile = try model.store.profile(personId: person.id)
            best = try model.store.bestCandidate(personId: person.id)
            sources = try model.store.pagesForAccepted(personId: person.id)
            signals = try model.store.signals(personId: person.id)
            // The link chip is about the identity that was settled on, so it asks the candidate
            // the profile came from rather than every candidate the scan turned up.
            selfLinked = try best.map { candidate in
                try model.store.evidence(candidateId: candidate.id).contains { $0.kind == .selfLink }
            } ?? false
            let stored = try model.store.note(personId: person.id)?.body ?? ""
            savedNote = stored
            note = stored
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Researches this one person again and then writes them up again: a fresh scan replaces
    /// their candidates and pages, and the extractor turns whatever that found into a profile.
    /// A provider that is missing or misconfigured fails the second half only, so the sources
    /// the scan just gathered are still there.
    private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        errorMessage = nil
        progress = nil

        let scanner = model.makeScanner()
        let personId = person.id
        refreshTask = model.track {
            for await event in await scanner.run(personIds: [personId]) {
                guard !Task.isCancelled else {
                    await scanner.cancel()
                    break
                }
                progress = event
            }

            guard !Task.isCancelled else {
                refreshing = false
                progress = nil
                return
            }

            do {
                let extractor = try model.makeExtractor(factCheck: true)
                for await event in await extractor.run(personIds: [personId]) {
                    guard !Task.isCancelled else {
                        await extractor.cancel()
                        break
                    }
                    progress = event
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            refreshing = false
            progress = nil
            guard !Task.isCancelled else { return }
            load()
            onChanged()
        }
    }

    /// Abandons a refresh whose answer has stopped mattering — the screen is going away, or is
    /// about to be about somebody else.
    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
        progress = nil
    }
}

/// Lays subviews out left to right and wraps to a new line when the next one won't fit — what a
/// row of variable-width tags needs, and what no stock SwiftUI container does.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = rows(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func rows(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, x + size.width > width {
                rows.append(current)
                current = Row()
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
