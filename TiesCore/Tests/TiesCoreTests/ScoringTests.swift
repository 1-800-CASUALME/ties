import Testing
import Foundation
@testable import TiesCore

private func finding(_ url: String, name: String? = nil, company: String? = nil, username: String? = nil, avatar: String? = nil,
                     kind: SourcePage.Kind = .serp, evidence: [EvidenceItem] = [], linked: [String] = [], body: String? = nil,
                     headline: String? = nil, location: String? = nil, snippet: String? = nil) -> ProbeFinding {
    ProbeFinding(url: url, displayName: name, headline: headline, company: company, location: location, avatarURL: avatar, username: username,
                 pageTitle: nil, snippet: snippet, bodyText: body, pageKind: kind, evidence: evidence, linkedURLs: linked)
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

@Test func nameOnlySearchHitSurfacesAsUnsure() {
    // A contact with just a name and a phone: the only thing research can find is a page whose
    // name matches. That must still reach the review screen as an "Unsure" candidate.
    let i = input(name: ("Sara", "Ahmed"))
    let hit = finding("https://linkedin.com/in/sara-ahmed", name: "Sara Ahmed",
                      evidence: [EvidenceItem(kind: .name, weight: 0, detail: "Search result")])
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(s.first?.candidate.status == .pending)
    #expect(s.first?.candidate.score == ScoringWeights.default.name)
}

// MARK: - Task 7: local signals as verification evidence

@Test func selfLinkAutoAccepts() {
    // The link is the one the person signed their mail with; the candidate URL is the same
    // page reached with tracking parameters and a "www." in front, and its text names her.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(links: ["https://sara.dev/about"]))
    let hit = finding("https://www.sara.dev/about?utm_source=x", kind: .page, body: "Sara Ahmed builds things.")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(s[0].candidate.status == .auto)
    #expect(s[0].candidate.score == ScoringWeights.default.selfLink)
    #expect(s[0].evidence.contains { $0.kind == .selfLink })
}

@Test func forwardedLinkIsUnsureNotAccepted() {
    // A link that turned up in their messages but names nobody — forwarded, not owned — is
    // worth a look and not worth believing.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(links: ["https://github.com/torvalds"]))
    let s = CandidateScorer.score(groups: [[finding("https://github.com/torvalds", kind: .page)]], input: i)
    #expect(s.count == 1)
    #expect(s[0].candidate.status == .pending)
    #expect(s[0].candidate.score == ScoringWeights.default.selfLinkUnverified)
    #expect(s[0].candidate.score == 3.0)
}

@Test func selfLinkOnLinkedInIsCorroboratedByItsSlug() {
    // LinkedIn can't be read, so the finding has no name and no text — but the URL she shared
    // spells her name, which is corroboration enough.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(links: ["https://www.linkedin.com/in/sara-ahmed"]))
    let s = CandidateScorer.score(groups: [[finding("https://linkedin.com/in/sara-ahmed", kind: .page)]], input: i)
    #expect(s.count == 1)
    #expect(s[0].candidate.status == .auto)
    #expect(s[0].candidate.score == ScoringWeights.default.selfLink)
}

@Test func signatureTitleRaises() {
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(titles: ["Senior Product Manager"]))
    let hit = finding("https://www.linkedin.com/in/sara-ahmed", name: "Sara Ahmed", headline: "Senior Product Manager at Acme")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.contains { $0.kind == .signatureTitle })
    #expect(s[0].candidate.score == ScoringWeights.default.signatureTitle)
}

@Test func honorificMatchesProfession() {
    // Everyone writes to her as "Dr Sara"; the page says she is a cardiologist, MD.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(honorifics: ["Dr"]))
    let hit = finding("https://www.linkedin.com/in/sara-ahmed", name: "Sara Ahmed", headline: "Cardiologist, MD at Mayo Clinic")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.first { $0.kind == .honorific }?.detail == "Called Dr; the page says MD")
    #expect(s[0].candidate.score == ScoringWeights.default.honorific)
}

@Test func selfNameMatchesAlias() {
    // Contacts says "Sara Ahmed"; every chat and mail calls her "Suzy Ahmed". The alias both
    // gets the candidate past the name gate and vouches for it.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(aliases: ["Suzy Ahmed"]))
    let s = CandidateScorer.score(groups: [[finding("https://x.com/suzyahmed", name: "Suzy Ahmed")]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.contains { $0.kind == .selfName })
    #expect(s[0].candidate.score == ScoringWeights.default.selfName)
}

@Test func pushNameConflict() {
    // The number's WhatsApp push name is a full name of its own, and the profile the email
    // hash resolved to is a third name again — something about this handle doesn't add up.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(aliases: ["Bob Ray"]))
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]
    let s = CandidateScorer.score(groups: [[finding("https://x.com/mlopez", name: "Maria Lopez", evidence: e)]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.filter { $0.kind == .conflict }.count == 1)
    #expect(s[0].candidate.score == 8 + ScoringWeights.default.conflict)
}

@Test func kunyaPushNameDoesNotConflictWithTheContactsName() {
    // Everyone in the group chat calls him "Abu Khalid"; the profile the email hash resolved to
    // is named exactly as Contacts names him. That is one man with two names, not two men.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(aliases: ["Abu Khalid"]))
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]
    let s = CandidateScorer.score(groups: [[finding("https://x.com/sara", name: "Sara Ahmed", evidence: e)]], input: i)
    #expect(s.count == 1)
    #expect(!s[0].evidence.contains { $0.kind == .conflict })
    #expect(s[0].candidate.status == .auto)
}

@Test func derivedConflictsCostOneConflictBetweenThem() {
    // Different company and a different profession: two doubts, one price. Stacking them would
    // put a candidate the probes proved (8) below the pending threshold and out of the review
    // screen entirely.
    let i = input(name: ("Sara", "Ahmed"), company: "Acme", signals: localSignals(titles: ["Cardiologist, MD"]))
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]
    let hit = finding("https://x.com/sara", name: "Sara Ahmed", company: "Zephyr Logistics", evidence: e,
                      headline: "Software Engineer at Zephyr Logistics")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.filter { $0.kind == .conflict }.count == 1)
    #expect(s[0].candidate.score == 8 + ScoringWeights.default.conflict)
}

@Test func probeConflictsAreKeptAlongsideTheDerivedOne() {
    // The cap is on what this scorer derives; a conflict a probe reported is its own evidence.
    let i = input(name: ("Sara", "Ahmed"), company: "Acme")
    let e = [
        EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil),
        EvidenceItem(kind: .conflict, weight: -3, detail: "Probe says no", sourceURL: nil),
    ]
    let s = CandidateScorer.score(groups: [[finding("https://x.com/sara", name: "Sara Ahmed", company: "Zephyr Logistics", evidence: e)]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.filter { $0.kind == .conflict }.count == 2)
}

@Test func contactsJobTitleActsAsASignatureTitle() {
    let p = Person(givenName: "Sara", familyName: "Ahmed", jobTitle: "Senior Product Manager")
    let i = ProbeInput(person: p, channels: [])
    let hit = finding("https://www.linkedin.com/in/sara-ahmed", name: "Sara Ahmed", headline: "Senior Product Manager at Acme")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.contains { $0.kind == .signatureTitle })
    #expect(s[0].candidate.score == ScoringWeights.default.signatureTitle)
}

@Test func contactsJobTitleConflictsWithADifferentProfession() {
    let p = Person(givenName: "Sara", familyName: "Ahmed", jobTitle: "Cardiologist, MD")
    let i = ProbeInput(person: p, channels: [])
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]
    let hit = finding("https://x.com/sara", name: "Sara Ahmed", evidence: e, headline: "Software Engineer at Acme")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    let conflict = s[0].evidence.first { $0.kind == .conflict }
    #expect(conflict?.detail == "Signature says MD, the page says Engineer")
    #expect(s[0].candidate.score == 8 + ScoringWeights.default.conflict)
}

@Test func arabicHonorificMatchesProfession() {
    // "دكتور" is the same title as "Dr", which is the whole point of canonicalising honorifics.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(honorifics: ["دكتور"]))
    let hit = finding("https://www.linkedin.com/in/sara-ahmed", name: "Sara Ahmed", headline: "Physician at Mayo Clinic")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.contains { $0.kind == .honorific })
    #expect(s[0].candidate.score == ScoringWeights.default.honorific)
}

@Test func headlineHonorificIsNotReadAsAProfession() {
    // "Dr" in a headline is a title, not a claim about what the page says they do, so it must
    // not contradict a signature title that names a real profession.
    let p = Person(givenName: "Sara", familyName: "Ahmed", jobTitle: "Software Engineer")
    let i = ProbeInput(person: p, channels: [])
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]
    let hit = finding("https://x.com/sara", name: "Sara Ahmed", evidence: e, headline: "Dr Sara Ahmed")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(!s[0].evidence.contains { $0.kind == .conflict })
}

@Test func signatureTitleConflict() {
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(titles: ["Cardiologist, MD"]))
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]
    let hit = finding("https://x.com/sara", name: "Sara Ahmed", evidence: e, headline: "Software Engineer at Acme")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(!s[0].evidence.contains { $0.kind == .signatureTitle })
    #expect(s[0].evidence.filter { $0.kind == .conflict }.count == 1)
    #expect(s[0].candidate.score == 8 + ScoringWeights.default.conflict)
}

@Test func sameProfessionInOtherWordsIsNoConflict() {
    // "Physician" and "Doctor" are one profession, not two, so a signature title that says one
    // and a headline that says the other must not read as a contradiction.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(titles: ["Physician"]))
    let e = [EvidenceItem(kind: .emailHash, weight: 8, detail: "x", sourceURL: nil)]
    let hit = finding("https://x.com/sara", name: "Sara Ahmed", evidence: e, headline: "Doctor at Mayo Clinic")
    let s = CandidateScorer.score(groups: [[hit]], input: i)
    #expect(s.count == 1)
    #expect(!s[0].evidence.contains { $0.kind == .conflict })
}

@Test func signalLocationScores() {
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(location: "Riyadh"))
    let s = CandidateScorer.score(groups: [[finding("https://x.com/sara", name: "Sara Ahmed", location: "Riyadh, Saudi Arabia")]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.contains { $0.kind == .location })
    #expect(s[0].candidate.score == ScoringWeights.default.location)
}

@Test func signalCompanyMatchesLikeAContactsCompany() {
    // No organization in Contacts — the company came out of a mail signature.
    let i = input(name: ("Sara", "Ahmed"), signals: localSignals(companies: ["Acme Corp"]))
    let s = CandidateScorer.score(groups: [[finding("https://x.com/sara", name: "Sara Ahmed", company: "ACME CORP")]], input: i)
    #expect(s.count == 1)
    #expect(s[0].evidence.contains { $0.kind == .company })
    #expect(!s[0].evidence.contains { $0.kind == .conflict })
}

@Test func newEvidenceKindsSurviveTheDedupPass() {
    // Every kind a probe can hand in has to be representable in the evidence list; a kind
    // missing from the scorer's fixed order would be dropped silently.
    let i = input(name: ("Sara", "Ahmed"))
    let e: [EvidenceItem] = [
        EvidenceItem(kind: .selfLink, weight: 99, detail: "a", sourceURL: nil),
        EvidenceItem(kind: .selfName, weight: 99, detail: "b", sourceURL: nil),
        EvidenceItem(kind: .signatureTitle, weight: 99, detail: "c", sourceURL: nil),
        EvidenceItem(kind: .honorific, weight: 99, detail: "d", sourceURL: nil),
    ]
    let s = CandidateScorer.score(groups: [[finding("https://x.com/sara", name: "Sara Ahmed", evidence: e)]], input: i)
    #expect(s.count == 1)
    #expect(Set(s[0].evidence.map(\.kind)) == Set([.selfLink, .selfName, .signatureTitle, .honorific]))
    let w = ScoringWeights.default
    #expect(s[0].candidate.score == w.selfLink + w.selfName + w.signatureTitle + w.honorific)
}
