import Foundation

/// Every word the five AI services say to a model.
///
/// One file, on purpose: what Ties sends to a provider — especially *which* facts about the
/// user's people it sends — is a privacy question before it is a prompt-engineering question,
/// and it can only be reviewed as a whole if it is written in one place. The services
/// themselves decide *whether* to pass a piece of information (§7.5: local signals reach a
/// cloud provider only when the user turned the switch on); these builders only decide how it
/// reads once it has been passed.
public enum AIPrompts {
    /// The longest any single quoted excerpt gets, in characters. Long enough to judge a
    /// snippet by, short enough that a dozen of them still leave room for the instructions.
    static let excerptLimit = 300

    // MARK: - Candidate judge (§7.1)

    public static let judgeSystem = """
        You decide which of several web search results is the same person as the one described. \
        Output only JSON matching the schema. \
        candidateId: the id of the candidate you pick, copied exactly from the list. \
        confidence: 0 to 1, how sure you are that this candidate is the same person. \
        reason: at most 90 characters, plain language, naming the detail that convinced you. \
        Namesakes are common: prefer the candidate whose company, title, or city matches the \
        known facts, and give a low confidence when nothing matches.
        """

    /// The judge's user message: who the person is, then one block per candidate.
    ///
    /// `signals` is what the caller was allowed to share — `nil` leaves the section out
    /// entirely rather than announcing that something was withheld.
    public static func judge(
        person: Person,
        candidates: [Candidate],
        pages: [String: [SourcePage]],
        signals: LocalSignals?
    ) -> String {
        var lines = ["Known facts from my address book:", "Name: \(person.displayName)"]
        if let company = nonEmpty(person.organization) { lines.append("Company: \(company)") }
        if let title = nonEmpty(person.jobTitle) { lines.append("Title: \(title)") }
        if let signals {
            lines += list("Known as", signals.aliases)
            lines += list("Addressed as", signals.honorifics)
            lines += list("Titles", signals.titles)
            lines += list("Companies", signals.companies)
            lines += list("Links", signals.links)
            if let location = nonEmpty(signals.location) { lines.append("Location: \(location)") }
        }

        lines.append("")
        lines.append("Candidates:")
        for candidate in candidates {
            lines.append("- id: \(candidate.id)")
            if let name = nonEmpty(candidate.displayName) { lines.append("  name: \(name)") }
            if let headline = nonEmpty(candidate.headline) { lines.append("  headline: \(headline)") }
            if let company = nonEmpty(candidate.company) { lines.append("  company: \(company)") }
            if let location = nonEmpty(candidate.location) { lines.append("  location: \(location)") }
            lines.append("  url: \(candidate.primaryURL)")
            for snippet in snippets(of: pages[candidate.id] ?? [], limit: 2) {
                lines.append("  snippet: \(snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Smart lists (§7.2)

    public static let smartListsSystem = """
        You group a person's professional network into a few useful lists. \
        Output only JSON matching the schema. \
        Make at most 8 lists, each named in 1 to 3 words ("Doctors", "Founders", "Engineers in Riyadh"). \
        Group by profession, industry, or skill — never by how well the owner knows them. \
        Every list needs at least 2 people; put a person in more than one list only when both \
        clearly fit; leave someone out entirely rather than inventing a group for them. \
        personIds: copy the ids exactly. systemImage: pick the closest symbol from the allowed list.
        """

    public static func smartLists(_ people: [(personId: String, occupation: String?, skills: [String])]) -> String {
        var lines = ["People (id, occupation, skills):"]
        for person in people {
            var parts = [person.personId]
            if let occupation = nonEmpty(person.occupation) { parts.append(occupation) }
            let skills = person.skills.compactMap(nonEmpty).prefix(8)
            if !skills.isEmpty { parts.append(skills.joined(separator: ", ")) }
            lines.append("- " + parts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Query expansion (§7.3)

    public static let queryExpansionSystem = """
        You turn a search for a person into the words that person's profile would use. \
        Output only JSON matching the schema. \
        terms: at most 6 role, job title, or skill terms — "help with taxes" becomes \
        accountant, CPA, tax advisor, bookkeeper. No sentences, no explanations, no names of \
        real people, and nothing already in the question.
        """

    public static func queryExpansion(_ query: String) -> String {
        "Question: \(query)"
    }

    // MARK: - Fact check (§7.6)

    public static let factCheckSystem = """
        You check extracted facts against the source text they came from. \
        Output only JSON matching the schema. \
        supported: one true/false per numbered fact, in the same order, and exactly as many \
        as there are facts. true only when the sources below the fact actually say it — not \
        when they merely make it plausible. A fact with no sources is false.
        """

    /// One numbered fact per block, each followed by the text of the pages it cites.
    public static func factCheck(facts: [Fact], pages: [SourcePage]) -> String {
        let byId = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = ["\(facts.count) facts to check:"]
        for (index, fact) in facts.enumerated() {
            lines.append("\(index + 1). \(fact.text)")
            let cited = fact.sources.compactMap { byId[$0] }
            if cited.isEmpty {
                lines.append("   sources: none")
            } else {
                for source in cited.prefix(3) {
                    lines.append("   source: \(excerpt(of: source))")
                }
            }
        }
        lines.append("")
        lines.append("Answer with exactly \(facts.count) booleans.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Message drafts (§7.4)

    public static let draftSystem = """
        You write one short message from the owner of this address book to one of their contacts. \
        Output only JSON matching the schema. \
        At most 60 words, no greeting longer than a line, no subject line, no signature, no \
        placeholders like [name]. Say what is needed and why them. \
        When past messages are shown, copy their register — length, greeting, formality, \
        language — but never their content.
        """

    public static func draft(need: String, person: Person, facts: ProfileFacts?, registerSample: [String]) -> String {
        var lines = ["Write to: \(person.displayName)"]
        if let company = nonEmpty(person.organization) { lines.append("Company: \(company)") }
        if let facts {
            if let occupation = nonEmpty(facts.occupation) { lines.append("Occupation: \(occupation)") }
            if let summary = nonEmpty(facts.summary) { lines.append("About them: \(summary)") }
            let skills = facts.canHelpWith.compactMap(nonEmpty).prefix(8)
            if !skills.isEmpty { lines.append("They can help with: \(skills.joined(separator: ", "))") }
        }
        lines.append("")
        lines.append("What I need: \(need)")

        // The caller decides whether a register sample may be sent at all (§7.5: on-device, or
        // the switch is on); only the most recent few are worth the context.
        let sample = registerSample.compactMap(nonEmpty).suffix(20)
        if !sample.isEmpty {
            lines.append("")
            lines.append("How I usually write to them:")
            lines += sample.map { "- \(truncated($0, to: excerptLimit))" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared formatting

    /// A page as one quoted line: title, snippet and the start of its body text, which is all
    /// the evidence there is for a page that was fetched rather than just listed.
    private static func excerpt(of page: SourcePage) -> String {
        let parts = [page.title, page.snippet, page.bodyText].compactMap(nonEmpty)
        let text = parts.isEmpty ? page.url : parts.joined(separator: " — ")
        return truncated(text, to: excerptLimit)
    }

    /// The first `limit` pages of a candidate, as excerpts.
    private static func snippets(of pages: [SourcePage], limit: Int) -> [String] {
        pages.prefix(limit).map { excerpt(of: $0) }
    }

    private static func list(_ label: String, _ values: [String]) -> [String] {
        let cleaned = values.compactMap(nonEmpty)
        return cleaned.isEmpty ? [] : ["\(label): \(cleaned.joined(separator: ", "))"]
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        let collapsed = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
