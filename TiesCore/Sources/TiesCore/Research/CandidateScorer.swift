import Foundation

/// The per-kind weights `CandidateScorer` uses to score a group of findings, and the score
/// thresholds that decide whether a candidate is auto-accepted, held for review, or dropped.
public struct ScoringWeights: Sendable {
    public var emailHash: Double
    public var phone: Double
    public var company: Double
    public var location: Double
    public var avatar: Double
    public var username: Double
    /// A page or profile whose name matches the contact. Small on its own — a namesake is
    /// still a namesake — but enough to surface the candidate as "Unsure" for a human to judge.
    public var name: Double
    /// A link the person shared or signed with themselves — they pointed at this profile, so on
    /// its own it is enough to auto-accept.
    public var selfLink: Double
    public var selfName: Double
    public var signatureTitle: Double
    public var honorific: Double
    public var conflict: Double
    public var autoThreshold: Double
    public var pendingThreshold: Double

    public init(
        emailHash: Double = 8.0,
        phone: Double = 6.0,
        company: Double = 3.0,
        location: Double = 1.5,
        avatar: Double = 2.0,
        username: Double = 1.5,
        name: Double = 1.0,
        selfLink: Double = 6.0,
        selfName: Double = 2.0,
        signatureTitle: Double = 2.0,
        honorific: Double = 1.0,
        conflict: Double = -3.0,
        autoThreshold: Double = 6.0,
        pendingThreshold: Double = 1.0
    ) {
        self.emailHash = emailHash
        self.phone = phone
        self.company = company
        self.location = location
        self.avatar = avatar
        self.username = username
        self.name = name
        self.selfLink = selfLink
        self.selfName = selfName
        self.signatureTitle = signatureTitle
        self.honorific = honorific
        self.conflict = conflict
        self.autoThreshold = autoThreshold
        self.pendingThreshold = pendingThreshold
    }

    public static let `default` = ScoringWeights()

    /// The weight this scorer assigns evidence of `kind`, regardless of what weight the probe
    /// that produced it supplied.
    func weight(for kind: Evidence.Kind) -> Double {
        switch kind {
        case .emailHash: return emailHash
        case .phone: return phone
        case .company: return company
        case .location: return location
        case .avatar: return avatar
        case .username: return username
        case .conflict: return conflict
        case .name: return name
        case .selfLink: return selfLink
        case .selfName: return selfName
        case .signatureTitle: return signatureTitle
        case .honorific: return honorific
        }
    }
}

/// A scored candidate identity: the `Candidate` record, the `Evidence` that produced its score,
/// and the `SourcePage`s (one per finding) the group was built from.
public struct ScoredCandidate: Sendable {
    public var candidate: Candidate
    public var evidence: [Evidence]
    public var pages: [SourcePage]

    public init(candidate: Candidate, evidence: [Evidence], pages: [SourcePage]) {
        self.candidate = candidate
        self.evidence = evidence
        self.pages = pages
    }
}

/// Scores groups of `ProbeFinding`s (as produced by `CandidateGrouper`) into `Candidate`s,
/// re-weighting every evidence item by kind rather than trusting the weight the probe supplied,
/// adding evidence derived from cross-checking the group against the `ProbeInput`, and gating
/// on whether the group plausibly names the person being researched at all.
public enum CandidateScorer {
    /// Evidence kinds considered in this fixed order when building a candidate's evidence list,
    /// so the output is deterministic regardless of dictionary iteration order. `.conflict`
    /// items aren't part of this dedup pass (every one is kept), so they're appended after.
    /// Ordered strongest first, so the evidence list reads as the reason the candidate scored
    /// what it did. Every kind must appear here: one left out is one dropped from the output.
    private static let dedupedKindOrder: [Evidence.Kind] = [
        .emailHash, .selfLink, .phone, .company, .signatureTitle, .selfName, .location, .avatar, .username, .honorific, .name,
    ]

    /// Honorific -> the profession words it implies, used both to credit a candidate whose
    /// headline says what the honorific claims and to spot a headline that contradicts the
    /// title in the person's mail signature.
    // TODO(Task 6): switch to Honorifics.professions
    private static let professionsByHonorific: [String: [String]] = [
        "dr": ["doctor", "physician", "dentist", "phd", "md"],
        "eng": ["engineer"],
        "prof": ["professor"],
        "capt": ["captain", "pilot"],
        "adv": ["lawyer", "attorney", "advocate"],
        "arch": ["architect"],
    ]

    /// Profession word -> the honorific it belongs to, so "Physician" and "Doctor" are read as
    /// one profession rather than two contradicting ones. Built once, over sorted keys so a
    /// word claimed by two honorifics resolves deterministically.
    private static let honorificByProfession: [String: String] = {
        var map: [String: String] = [:]
        for honorific in professionsByHonorific.keys.sorted() {
            for profession in professionsByHonorific[honorific] ?? [] {
                map[profession] = honorific
            }
        }
        return map
    }()

    public static func score(groups: [[ProbeFinding]], input: ProbeInput, weights: ScoringWeights = .default) -> [ScoredCandidate] {
        // Pair each scored candidate with its original group index before sorting, so that
        // candidates tying on score keep a deterministic order (first-appearing group wins)
        // instead of depending on the sort algorithm's incidental stability.
        var indexed: [(index: Int, scored: ScoredCandidate)] = []
        for (index, group) in groups.enumerated() {
            if let scored = scoreGroup(group, input: input, weights: weights) {
                indexed.append((index: index, scored: scored))
            }
        }
        indexed.sort { (-$0.scored.candidate.score, $0.index) < (-$1.scored.candidate.score, $1.index) }
        var results = indexed.map(\.scored)

        let autoIndices = results.indices.filter { results[$0].candidate.status == .auto }
        if autoIndices.count > 1 {
            for i in autoIndices {
                results[i].candidate.status = .pending
            }
        }

        return results
    }

    private static func scoreGroup(_ group: [ProbeFinding], input: ProbeInput, weights: ScoringWeights) -> ScoredCandidate? {
        let selfLink = selfLinkMatch(group, input: input)
        guard passesNameGate(group, input: input, hasSelfLink: selfLink != nil) else { return nil }

        let candidateId = UUID().uuidString

        // Union of finding evidence, kept at most once per non-conflict kind (first seen);
        // every `.conflict` item is kept.
        var kept: [Evidence.Kind: EvidenceItem] = [:]
        var conflictItems: [EvidenceItem] = []
        for finding in group {
            for item in finding.evidence {
                if item.kind == .conflict {
                    conflictItems.append(item)
                } else if kept[item.kind] == nil {
                    kept[item.kind] = item
                }
            }
        }

        // Field priority: gravatar -> github -> serp(LinkedIn first) -> serp -> page -> username.
        // Tie-break on the original index so findings of equal rank keep their original
        // relative order deterministically, instead of relying on `sorted`'s incidental stability.
        let ordered = group.enumerated()
            .sorted { (priorityRank($0.element), $0.offset) < (priorityRank($1.element), $1.offset) }
            .map(\.element)
        let displayName = ordered.lazy.compactMap(\.displayName).first
        let headline = ordered.lazy.compactMap(\.headline).first
        let groupCompany = ordered.lazy.compactMap(\.company).first
        let location = ordered.lazy.compactMap(\.location).first
        let avatarURL = ordered.lazy.compactMap(\.avatarURL).first

        // Derived: phone number appears in a finding's body/snippet text.
        if kept[.phone] == nil, hasPhoneMatch(group, input: input) {
            kept[.phone] = EvidenceItem(kind: .phone, weight: weights.phone, detail: "Phone number match", sourceURL: nil)
        }

        // Derived: company agrees with (or conflicts with) the contact's known company.
        // Normalized (case/diacritic/punctuation-insensitive) before comparing: raw jaroWinkler
        // on strings differing only in case (e.g. "ACME CORP" vs "acme corp") can score well
        // under 0.9 and even under 0.5, which would otherwise manufacture a false conflict for
        // the very same company.
        //
        // Every company we know of counts — the Contacts organization and any read out of a
        // mail signature — so the candidate agrees if it matches one of them, and only
        // conflicts if it matches none.
        if let groupCompany, !input.companies.isEmpty {
            let normalizedGroupCompany = NameMatcher.normalize(groupCompany)
            let similarity = input.companies
                .map { NameMatcher.jaroWinkler(NameMatcher.normalize($0), normalizedGroupCompany) }
                .max() ?? 0
            if similarity >= 0.9 {
                if kept[.company] == nil {
                    kept[.company] = EvidenceItem(kind: .company, weight: weights.company, detail: "Company matches: \(groupCompany)", sourceURL: nil)
                }
            } else if similarity < 0.5 {
                conflictItems.append(EvidenceItem(kind: .conflict, weight: weights.conflict, detail: "Different company: \(groupCompany)", sourceURL: nil))
            }
        }

        // Derived: two findings in the group share a username on different hosts. An empty
        // string isn't a real username, so it's excluded to avoid two findings with a blank
        // `username` field falsely "sharing" one.
        if kept[.username] == nil, sharedAcrossHosts(group, value: { nonEmpty($0.username)?.lowercased() }) {
            kept[.username] = EvidenceItem(kind: .username, weight: weights.username, detail: "Shared username across profiles", sourceURL: nil)
        }

        // Derived: two findings in the group share an avatar URL on different hosts. Same
        // empty-string guard as username above.
        if kept[.avatar] == nil, sharedAcrossHosts(group, value: { nonEmpty($0.avatarURL) }) {
            kept[.avatar] = EvidenceItem(kind: .avatar, weight: weights.avatar, detail: "Shared avatar across profiles", sourceURL: nil)
        }

        // Derived: the person pointed at this page themselves, in a message or a signature.
        if kept[.selfLink] == nil, let selfLink {
            kept[.selfLink] = EvidenceItem(kind: .selfLink, weight: weights.selfLink, detail: "They shared this link themselves", sourceURL: selfLink)
        }

        // Derived: the candidate goes by a name the person actually answers to — or by one that
        // rules them out, when the handle's push name is somebody else's full name entirely.
        if let displayName {
            if kept[.selfName] == nil, let alias = matchingAlias(displayName, input: input) {
                kept[.selfName] = EvidenceItem(kind: .selfName, weight: weights.selfName, detail: "Known as \(alias)", sourceURL: nil)
            } else if kept[.selfName] == nil, let alias = conflictingAlias(displayName, input: input) {
                conflictItems.append(EvidenceItem(kind: .conflict, weight: weights.conflict, detail: "Known as \(alias), not \(displayName)", sourceURL: nil))
            }
        }

        // Derived: the headline says what their mail signature says — or says a different
        // profession outright.
        if let headline {
            if kept[.signatureTitle] == nil, let title = input.titles.first(where: { titleMatches(headline, title: $0) }) {
                kept[.signatureTitle] = EvidenceItem(kind: .signatureTitle, weight: weights.signatureTitle, detail: "Signature title matches: \(title)", sourceURL: nil)
            } else if let clash = professionConflict(headline: headline, input: input) {
                conflictItems.append(EvidenceItem(kind: .conflict, weight: weights.conflict, detail: "Signature says \(clash.theirs), the page says \(clash.page)", sourceURL: nil))
            }
        }

        // Derived: the page names a profession the honorific other people use implies.
        if kept[.honorific] == nil,
           let match = honorificMatch(in: group.flatMap { [$0.headline, $0.snippet].compactMap(\.self) }, input: input) {
            kept[.honorific] = EvidenceItem(kind: .honorific, weight: weights.honorific, detail: "Called \(match.honorific); the page says \(match.profession)", sourceURL: nil)
        }

        // Derived: the city the Mac already knows agrees with the candidate's.
        if kept[.location] == nil, let location, let signalLocation = nonEmpty(input.signals?.location), locationMatches(location, signalLocation) {
            kept[.location] = EvidenceItem(kind: .location, weight: weights.location, detail: "Location matches: \(location)", sourceURL: nil)
        }

        var evidence: [Evidence] = []
        for kind in dedupedKindOrder {
            guard let item = kept[kind] else { continue }
            evidence.append(Evidence(candidateId: candidateId, kind: kind, weight: weights.weight(for: kind), detail: item.detail, sourceURL: item.sourceURL))
        }
        for item in conflictItems {
            evidence.append(Evidence(candidateId: candidateId, kind: .conflict, weight: weights.conflict, detail: item.detail, sourceURL: item.sourceURL))
        }

        let score = evidence.reduce(0) { $0 + $1.weight }
        let status: Candidate.Status
        if score >= weights.autoThreshold {
            status = .auto
        } else if score >= weights.pendingThreshold {
            status = .pending
        } else {
            return nil
        }

        let candidate = Candidate(
            id: candidateId,
            personId: input.person.id,
            score: score,
            status: status,
            displayName: displayName,
            headline: headline,
            company: groupCompany,
            location: location,
            avatarURL: avatarURL,
            primaryURL: primaryURL(for: group)
        )

        let pages = group.map { finding in
            SourcePage(
                candidateId: candidateId,
                url: finding.url,
                title: finding.pageTitle,
                snippet: finding.snippet,
                bodyText: finding.bodyText,
                fetchedAt: .now,
                kind: finding.pageKind
            )
        }

        return ScoredCandidate(candidate: candidate, evidence: evidence, pages: pages)
    }

    /// Passes when any finding's `displayName` is a plausible match for any name the contact
    /// goes by (the one in Contacts or an alias the local signals collected), or the group is a
    /// link the person shared themselves, or any finding carries `.emailHash` evidence (a
    /// hashed-identity match is proof enough on its own), or any finding's body text mentions
    /// the contact's name.
    private static func passesNameGate(_ group: [ProbeFinding], input: ProbeInput, hasSelfLink: Bool) -> Bool {
        // They pointed at this page themselves, so it identifies them whether or not it repeats
        // their name — a personal site's landing page often doesn't.
        if hasSelfLink { return true }

        let names = input.aliases
        let nameMatches = group.contains { finding in
            guard let name = finding.displayName else { return false }
            return names.contains { NameMatcher.similarity(personName: $0, candidateName: name) >= NameMatcher.gate }
        }
        if nameMatches { return true }

        let hasEmailHash = group.contains { finding in finding.evidence.contains { $0.kind == .emailHash } }
        if hasEmailHash { return true }

        return group.contains { finding in
            guard let body = finding.bodyText else { return false }
            return NameMatcher.containsName(body, personName: input.fullName)
        }
    }

    /// The URL of the first finding in the group that the person shared or signed with
    /// themselves, compared in `ProbeFinding.canonical` form. A finding that merely vouches for
    /// such a URL (a Gravatar's verified accounts) counts too.
    private static func selfLinkMatch(_ group: [ProbeFinding], input: ProbeInput) -> String? {
        guard let links = input.signals?.links, !links.isEmpty else { return nil }
        let shared = Set(links.map(canonicalLink))

        for finding in group {
            if shared.contains(canonicalLink(finding.url)) { return finding.url }
            if let linked = finding.linkedURLs.first(where: { shared.contains(canonicalLink($0)) }) { return linked }
        }
        return nil
    }

    /// `ProbeFinding.canonical` with a bare trailing slash dropped as well, so "https://sara.dev"
    /// and "https://sara.dev/" are one link.
    private static func canonicalLink(_ url: String) -> String {
        var canonical = ProbeFinding.canonical(url)
        if canonical.hasSuffix("/") { canonical.removeLast() }
        return canonical
    }

    /// The first alias the person actually goes by that this candidate's display name matches.
    /// An alias that is just the Contacts name again doesn't count — a candidate matching that
    /// is what `.name` evidence is for.
    private static func matchingAlias(_ displayName: String, input: ProbeInput) -> String? {
        input.signals?.aliases.first { alias in
            NameMatcher.similarity(personName: input.fullName, candidateName: alias) < NameMatcher.gate
                && NameMatcher.similarity(personName: alias, candidateName: displayName) >= NameMatcher.gate
        }
    }

    /// An alias that is a full name in its own right — two tokens — sharing not one word with
    /// the candidate's display name. That is the shape of a shared handle whose WhatsApp push
    /// name belongs to somebody else in the household or the office, which is a reason to doubt
    /// the candidate rather than to believe it.
    ///
    /// Sharing no word isn't quite enough on its own: "Mohammed Ali" and "Mohamed Aly" have no
    /// word in common and are the same man, so a pair that `NameMatcher` still reads as a match
    /// is spelling, not contradiction. (The similarity has to be read against the match gate
    /// rather than some lower line: nickname expansion alone puts two names as unalike as "Bob
    /// Ray" and "Sara Ahmed" at 0.53, because "Bob" becomes "Robert".)
    private static func conflictingAlias(_ displayName: String, input: ProbeInput) -> String? {
        guard let aliases = input.signals?.aliases else { return nil }
        let candidateTokens = Set(tokens(displayName))

        return aliases.first { alias in
            let aliasTokens = tokens(alias)
            guard aliasTokens.count == 2, candidateTokens.isDisjoint(with: aliasTokens) else { return false }
            return NameMatcher.similarity(personName: alias, candidateName: displayName) < NameMatcher.gate
        }
    }

    /// True when the headline says what the signature title says: the title appears in it
    /// outright, or some run of words in it is the title bar a word ending (JW >= 0.85).
    private static func titleMatches(_ headline: String, title: String) -> Bool {
        let normalizedTitle = NameMatcher.normalize(title)
        let normalizedHeadline = NameMatcher.normalize(headline)
        guard !normalizedTitle.isEmpty, !normalizedHeadline.isEmpty else { return false }
        if normalizedHeadline.contains(normalizedTitle) { return true }

        let headlineTokens = tokens(headline)
        let titleTokenCount = tokens(title).count
        guard titleTokenCount > 0, headlineTokens.count >= titleTokenCount else {
            return NameMatcher.jaroWinkler(normalizedHeadline, normalizedTitle) >= 0.85
        }
        for start in 0...(headlineTokens.count - titleTokenCount) {
            let window = headlineTokens[start..<(start + titleTokenCount)].joined(separator: " ")
            if NameMatcher.jaroWinkler(window, normalizedTitle) >= 0.85 { return true }
        }
        return false
    }

    /// The professions a signature title and a candidate headline name when they are different
    /// professions altogether — "Cardiologist, MD" against "Software Engineer". Only words in
    /// `professionsByHonorific` count, and only their honorific families are compared, so
    /// "Physician" against "Doctor" is one profession said twice rather than a contradiction,
    /// and two titles the map has never heard of never conflict.
    private static func professionConflict(headline: String, input: ProbeInput) -> (theirs: String, page: String)? {
        let page = professions(in: headline)
        let theirs = input.titles.flatMap { professions(in: $0) }
        guard let firstPage = page.first, let firstTheirs = theirs.first else { return nil }
        guard Set(theirs.map(\.honorific)).isDisjoint(with: page.map(\.honorific)) else { return nil }
        return (theirs: firstTheirs.word, page: firstPage.word)
    }

    /// The honorific the person is addressed by and the profession word the pages actually use,
    /// when the two agree — "Dr" and a headline reading "Cardiologist, MD".
    private static func honorificMatch(in texts: [String], input: ProbeInput) -> (honorific: String, profession: String)? {
        guard let honorifics = input.signals?.honorifics, !honorifics.isEmpty, !texts.isEmpty else { return nil }
        let words = Set(texts.flatMap(tokens))

        for honorific in honorifics {
            let implied = professionsByHonorific[canonicalHonorific(honorific)] ?? []
            if let hit = implied.first(where: { words.contains($0) }) {
                return (honorific: honorific, profession: hit)
            }
        }
        return nil
    }

    /// The profession words a piece of text uses, each with the honorific family it belongs to,
    /// in the order they appear.
    private static func professions(in text: String) -> [(word: String, honorific: String)] {
        tokens(text).compactMap { word in
            honorificByProfession[word].map { (word: word, honorific: $0) }
        }
    }

    /// An honorific reduced to the key `professionsByHonorific` uses: "Dr." and "DR" are both
    /// "dr". Arabic spellings are left as written and so simply don't match, until this reads
    /// the real vocabulary.
    // TODO(Task 6): switch to Honorifics.professions
    private static func canonicalHonorific(_ honorific: String) -> String {
        honorific.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    /// True when a candidate's location and the one the Mac already knows name the same place:
    /// one contains the other ("Riyadh" in "Riyadh, Saudi Arabia") or they are the same word bar
    /// a spelling (JW >= 0.9).
    private static func locationMatches(_ candidate: String, _ known: String) -> Bool {
        let a = NameMatcher.normalize(candidate)
        let b = NameMatcher.normalize(known)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.contains(b) || b.contains(a) { return true }
        return NameMatcher.jaroWinkler(a, b) >= 0.9
    }

    /// The normalized words of a string.
    private static func tokens(_ s: String) -> [String] {
        NameMatcher.normalize(s).split(separator: " ").map(String.init)
    }

    /// True when any of the contact's known phone numbers' last 7 digits appear in any
    /// finding's body text or snippet.
    private static func hasPhoneMatch(_ group: [ProbeFinding], input: ProbeInput) -> Bool {
        let haystacks = group.flatMap { [$0.bodyText, $0.snippet].compactMap { $0 } }.map(PhoneNormalizer.digits)
        guard !haystacks.isEmpty else { return false }

        for phone in input.phonesE164 {
            let phoneDigits = PhoneNormalizer.digits(phone)
            guard phoneDigits.count >= 7 else { continue }
            let last7 = phoneDigits.suffix(7)
            if haystacks.contains(where: { $0.contains(last7) }) {
                return true
            }
        }
        return false
    }

    /// True when two findings in the group have equal, non-nil values for `value` while their
    /// URLs resolve to different hosts.
    private static func sharedAcrossHosts(_ group: [ProbeFinding], value: (ProbeFinding) -> String?) -> Bool {
        for i in 0..<group.count {
            guard let v1 = value(group[i]) else { continue }
            let host1 = host(of: group[i].url)
            for j in (i + 1)..<group.count {
                guard let v2 = value(group[j]), v1 == v2 else { continue }
                if host(of: group[j].url) != host1 {
                    return true
                }
            }
        }
        return false
    }

    /// `nil` for `nil` or an empty string, so callers can treat a blank field the same as an
    /// absent one.
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func host(of url: String) -> String? {
        URLComponents(string: url)?.host?.lowercased()
    }

    private static func isLinkedIn(_ url: String) -> Bool {
        host(of: url)?.contains("linkedin.com") ?? false
    }

    private static func priorityRank(_ finding: ProbeFinding) -> Int {
        switch finding.pageKind {
        case .gravatar: return 0
        case .github: return 1
        case .serp: return isLinkedIn(finding.url) ? 2 : 3
        case .page: return 4
        case .username: return 5
        }
    }

    /// The first non-LinkedIn finding's URL when the group has `.emailHash` evidence (a strong
    /// identity match makes the non-LinkedIn page the more useful primary link); otherwise the
    /// first LinkedIn URL if the group has one; otherwise the first finding's URL.
    private static func primaryURL(for group: [ProbeFinding]) -> String {
        let hasEmailHash = group.contains { finding in finding.evidence.contains { $0.kind == .emailHash } }
        if hasEmailHash, let nonLinkedIn = group.first(where: { !isLinkedIn($0.url) }) {
            return nonLinkedIn.url
        }
        if let linkedIn = group.first(where: { isLinkedIn($0.url) }) {
            return linkedIn.url
        }
        return group[0].url
    }
}
