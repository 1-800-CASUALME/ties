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
    private static let dedupedKindOrder: [Evidence.Kind] = [.emailHash, .phone, .company, .location, .avatar, .username, .name]

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
        guard passesNameGate(group, input: input) else { return nil }

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
        if let inputCompany = input.company, let groupCompany {
            let similarity = NameMatcher.jaroWinkler(NameMatcher.normalize(inputCompany), NameMatcher.normalize(groupCompany))
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

    /// Passes when any finding's `displayName` is a plausible match for the contact's name, or
    /// any finding carries `.emailHash` evidence (a hashed-identity match is proof enough on its
    /// own), or any finding's body text mentions the contact's name.
    private static func passesNameGate(_ group: [ProbeFinding], input: ProbeInput) -> Bool {
        let nameMatches = group.contains { finding in
            guard let name = finding.displayName else { return false }
            return NameMatcher.similarity(personName: input.fullName, candidateName: name) >= NameMatcher.gate
        }
        if nameMatches { return true }

        let hasEmailHash = group.contains { finding in finding.evidence.contains { $0.kind == .emailHash } }
        if hasEmailHash { return true }

        return group.contains { finding in
            guard let body = finding.bodyText else { return false }
            return NameMatcher.containsName(body, personName: input.fullName)
        }
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
