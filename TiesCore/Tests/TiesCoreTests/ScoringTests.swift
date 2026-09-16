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
    #expect(s.isEmpty)   // 0 + (−3) < 2
}

@Test func phoneInBodyScores() {
    let p = Person(givenName: "Sara", familyName: "Ahmed")
    let i = ProbeInput(person: p, channels: [Channel(personId: p.id, kind: .phone, label: nil, value: "+15550100100", normalized: "+15550100100")])
    let s = CandidateScorer.score(groups: [[finding("https://sara.dev", name: "Sara Ahmed", kind: .page, body: "Call Sara Ahmed on +1 555 010 0100")]], input: i)
    #expect(s.first?.candidate.status == .auto)
    #expect(s.first?.evidence.contains { $0.kind == .phone } == true)
}
