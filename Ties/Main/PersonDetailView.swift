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
        .onDisappear { noteTask?.cancel() }
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
                            Text(fact.text)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
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
    private func scheduleNoteSave(_ text: String) {
        guard text != savedNote else { return }
        noteTask?.cancel()
        let personId = person.id
        noteTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try model.store.upsertNote(Note(personId: personId, body: text))
                savedNote = text
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
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

    private func load() {
        do {
            channels = try model.store.channels(personId: person.id)
            profile = try model.store.profile(personId: person.id)
            best = try model.store.bestCandidate(personId: person.id)
            sources = try model.store.pagesForAccepted(personId: person.id)
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
        refreshTask = Task {
            for await event in await scanner.run(personIds: [personId]) {
                progress = event
            }
            guard !Task.isCancelled else {
                refreshing = false
                return
            }
            do {
                let extractor = try model.makeExtractor()
                for await event in await extractor.run(personIds: [personId]) {
                    progress = event
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            refreshing = false
            progress = nil
            load()
            onChanged()
        }
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
