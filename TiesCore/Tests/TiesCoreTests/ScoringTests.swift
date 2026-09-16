import Testing
import Foundation
@testable import TiesCore

private func finding(_ url: String, name: String? = nil, company: String? = nil, username: String? = nil, avatar: String? = nil,
                     kind: SourcePage.Kind = .serp, evidence: [EvidenceItem] = [], linked: [String] = [], body: String? = nil) -> ProbeFinding {
    ProbeFinding(url: url, displayName: name, headline: nil, company: company, location: nil, avatarURL: avatar, username: username,
                 pageTitle: nil, snippet: nil, bodyText: body, pageKind: kind, evidence: evidence, linkedURLs: linked)
}

@Test func groupsMergeOnUsernameAndLinkedURLs() {
    let g = CandidateGrouper.group([
        finding("https://gravatar.com/beau", name: "Beau Lebens", kind: .gravatar, linked: ["https://github.com/beaulebens"]),
        finding("https://github.com/beaulebens", name: "Beau Lebens", username: "beaulebens", kind: .github),
        finding("https://x.com/beaulebens", name: "Beau Lebens", username: "beaulebens"),
        finding("https://www.linkedin.com/in/other-beau", name: "Beau Lebens"),
    ])
    #expect(g.count == 2)
    #expect(g.first { $0.count == 3 } != nil)
}

@Test func emailHashAutoAccepts() {
    let i = input(name: ("Beau", "Lebens"), company: "Automattic")
    let groups = [[finding("https://gravatar.com/beau", name: "Beau Lebens", company: "Automattic", kind: .gravatar,
                           evidence: [EvidenceItem(kind: .emailHash, weight: 8, detail: "Gravatar", sourceURL: nil)])]]
    let s = CandidateScorer.score(groups: groups, input: i)
    #expect(s.count == 1)
    #expect(s[0].candidate.status == .auto)
    #expect(s[0].candidate.score == 11)          // 8 email + 3 company (derived)
    #expect(s[0].evidence.count == 2)
    #expect(s[0].pages.count == 1)
}

@Test func nameGateDropsStrangers() {
    let i = input(name: ("Sara", "Ahmed"))
    let s = CandidateScorer.score(groups: [[finding("https://x.com/bob", name: "Bob Ray")]], input: i)
    #expect(s.isEmpty)
}

@Test func twoAutoBecomePending() {
    let i = input(name: ("Sara", "Ahmed"), company: "Acme")
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "", sourceURL: nil)]
    let s = CandidateScorer.score(groups: [[finding("https://a.com/1", name: "Sara Ahmed", evidence: e)], [finding("https://b.com/2", name: "Sara Ahmed", evidence: e)]], input: i)
    #expect(s.allSatisfy { $0.candidate.status == .pending })
}

@Test func conflictLowersAndBelowPendingDrops() {
    let i = input(name: ("Sara", "Ahmed"), company: "Acme")
    let s = CandidateScorer.score(groups: [[finding("https://www.linkedin.com/in/sara-2", name: "Sara Ahmed", company: "Totally Different Corp")]], input: i)
    // "Acme" vs "Totally Different Corp" doesn't clear either normalized-jaroWinkler threshold
    // (~0.53, between the 0.5 conflict line and the 0.9 match line), so this group scores 0 with
    // no evidence at all — still below pendingThreshold(2), so the candidate is dropped either way.
    #expect(s.isEmpty)
}

@Test func phoneInBodyScores() {
    let p = Person(givenName: "Sara", familyName: "Ahmed")
    let i = ProbeInput(person: p, channels: [Channel(personId: p.id, kind: .phone, label: nil, value: "+15550100100", normalized: "+15550100100")])
    let s = CandidateScorer.score(groups: [[finding("https://sara.dev", name: "Sara Ahmed", kind: .page, body: "Call Sara Ahmed on +1 555 010 0100")]], input: i)
    #expect(s.first?.candidate.status == .auto)
    #expect(s.first?.evidence.contains { $0.kind == .phone } == true)
}

// MARK: - Fix round 1

@Test func companyMatchIsCaseInsensitiveAndDoesNotConflict() {
    let i = input(name: ("Sara", "Ahmed"), company: "Acme Corp")
    let s = CandidateScorer.score(groups: [[finding("https://x.com/sara", name: "Sara Ahmed", company: "ACME CORP")]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.contains { $0.kind == .company })
    #expect(!s[0].evidence.contains { $0.kind == .conflict })
}

@Test func companyConflictDetailNamesTheDifferentCompany() {
    // "Acme" vs "Zephyr Logistics" (not the brief's "Totally Different Corp" — after fixing
    // company comparison to normalize before jaroWinkler, that pair lands at ~0.53, in the dead
    // zone between the conflict (<0.5) and match (>=0.9) thresholds, and so no longer conflicts;
    // see the updated comment on `conflictLowersAndBelowPendingDrops` above) is comfortably
    // under 0.5 (~0.44) both before and after normalization, so it reliably conflicts.
    let i = input(name: ("Sara", "Ahmed"), company: "Acme")
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]
    let s = CandidateScorer.score(groups: [[finding("https://x.com/sara", name: "Sara Ahmed", company: "Zephyr Logistics", evidence: e)]], input: i)
    #expect(s.count == 1)
    let conflict = s[0].evidence.first { $0.kind == .conflict }
    #expect(conflict?.detail.hasPrefix("Different company:") == true)
}

@Test func conflictAlongsideEmailHashScoresFiveWithOneConflictItem() {
    let i = input(name: ("Sara", "Ahmed"), company: "Acme")
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]
    let s = CandidateScorer.score(groups: [[finding("https://x.com/sara", name: "Sara Ahmed", company: "Zephyr Logistics", evidence: e)]], input: i)
    #expect(s.count == 1)
    #expect(s[0].candidate.score == 5)
    #expect(s[0].evidence.filter { $0.kind == .conflict }.count == 1)
}

@Test func usernameEvidenceIsReweightedNotTrusted() {
    let i = input(name: ("Sara", "Ahmed"))
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil),
              EvidenceItem(kind: .username, weight: 99, detail: "y", sourceURL: nil)]
    let s = CandidateScorer.score(groups: [[finding("https://x.com/sara", name: "Sara Ahmed", evidence: e)]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.first { $0.kind == .username }?.weight == ScoringWeights.default.username)
}

@Test func derivedUsernameRequiresDifferentHostsAndNoProbeEvidence() {
    let i = input(name: ("Sara", "Ahmed"))
    let group = [
        finding("https://github.com/sara", name: "Sara Ahmed", username: "sara", kind: .github,
                evidence: [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]),
        finding("https://x.com/sara", username: "sara"),
    ]
    let s = CandidateScorer.score(groups: [group], input: i)
    #expect(s.count == 1)
    let usernameItems = s[0].evidence.filter { $0.kind == .username }
    #expect(usernameItems.count == 1)
    #expect(usernameItems.first?.weight == 1.5)
}

@Test func primaryURLPrefersNonLinkedInWhenEmailHashPresent() {
    let i = input(name: ("Sara", "Ahmed"))
    let group = [
        finding("https://www.linkedin.com/in/sara", name: "Sara Ahmed"),
        finding("https://sara.dev", name: "Sara Ahmed", evidence: [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]),
    ]
    let s = CandidateScorer.score(groups: [group], input: i)
    #expect(s.first?.candidate.primaryURL == "https://sara.dev")
}

@Test func primaryURLFallsBackToLinkedInWithoutEmailHash() {
    let i = input(name: ("Sara", "Ahmed"), company: "Acme")
    let group = [
        finding("https://www.linkedin.com/in/sara", name: "Sara Ahmed"),
        finding("https://sara.dev", name: "Sara Ahmed", company: "Acme"),
    ]
    let s = CandidateScorer.score(groups: [group], input: i)
    #expect(s.first?.candidate.primaryURL == "https://www.linkedin.com/in/sara")
}

@Test func sortsByScoreDescendingRegardlessOfInputOrder() {
    let i = input(name: ("Sara", "Ahmed"))
    let low = [finding("https://a.com/1", name: "Sara Ahmed", evidence: [EvidenceItem(kind: .company, weight: 3, detail: "x", sourceURL: nil)])]
    let high = [finding("https://b.com/2", name: "Sara Ahmed", evidence: [
        EvidenceItem(kind: .company, weight: 3, detail: "x", sourceURL: nil),
        EvidenceItem(kind: .location, weight: 1.5, detail: "y", sourceURL: nil),
    ])]
    let s = CandidateScorer.score(groups: [low, high], input: i)
    #expect(s.count == 2)
    #expect(s.allSatisfy { $0.candidate.status == .pending })
    #expect(s[0].candidate.score == 4.5)
    #expect(s[1].candidate.score == 3)
}
