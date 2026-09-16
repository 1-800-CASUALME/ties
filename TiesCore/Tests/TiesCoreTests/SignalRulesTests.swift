import Testing
@testable import TiesCore

@Test func detectsEnglishAndArabicHonorifics() {
    #expect(SignalRules.honorifics(in: "ask Dr. Sara about it", names: ["Sara", "Ahmed"]) == ["dr"])
    #expect(SignalRules.honorifics(in: "كلمت المهندس أحمد امس", names: ["Ahmed", "أحمد"]) == ["eng"])
    #expect(SignalRules.honorifics(in: "Dr. Bob and Sara", names: ["Sara"]).isEmpty)
}

@Test func canonicalisesHonorificTokens() {
    #expect(Honorifics.canonical("Dr.") == "dr")
    #expect(Honorifics.canonical("DR") == "dr")
    #expect(Honorifics.canonical("دكتور") == "dr")
    // Arabic without diacritics and with the definite article attached.
    #expect(Honorifics.canonical("المهندسة") == "eng")
    #expect(Honorifics.canonical("م.") == "eng")
    #expect(Honorifics.canonical("shipping") == nil)
    #expect(Honorifics.professions(for: "dr").contains("physician"))
    #expect(Honorifics.professions(for: "sheikh").isEmpty)
    #expect(Honorifics.professions(for: "not-an-honorific").isEmpty)
}

@Test func honorificsAreDedupedInFirstSeenOrder() {
    let text = "Dr. Sara said Prof. Ahmed and Dr. Ahmed agreed"
    #expect(SignalRules.honorifics(in: text, names: ["Sara", "Ahmed"]) == ["dr", "prof"])
}

@Test func parsesThreeSignatureLayouts() throws {
    let a = "Thanks for the call.\n\nBest,\nSara Ahmed\nSenior Product Manager | Acme Corp\n+966 50 123 4567\nhttps://www.linkedin.com/in/sara-ahmed/"
    let s = try #require(SignalRules.signature(in: a, senderName: "Sara Ahmed"))
    #expect(s.titles == ["Senior Product Manager"])
    #expect(s.companies == ["Acme Corp"])
    #expect(s.phones == ["+966501234567"])
    #expect(s.links == ["https://linkedin.com/in/sara-ahmed"])
    #expect(s.name == "Sara Ahmed")
    let b = "…\n--\nSara Ahmed, Cardiologist at King Faisal Hospital\nRiyadh"
    let sb = try #require(SignalRules.signature(in: b, senderName: nil))
    #expect(sb.titles == ["Cardiologist"])
    #expect(sb.companies == ["King Faisal Hospital"])
    #expect(sb.location == "Riyadh")
    #expect(sb.name == "Sara Ahmed")
    let c = "Sara Ahmed\nEngineer\nAcme"
    #expect(SignalRules.signature(in: c, senderName: "Sara Ahmed")?.titles == ["Engineer"])
}

@Test func rejectsNewslettersAndQuotedReplies() {
    let n = "Regards\nTeam\nhttps://a.com https://b.com https://c.com https://d.com"
    #expect(SignalRules.signature(in: n, senderName: nil) == nil)
    let q = "> On Monday Sara wrote:\n> Regards\n> Sara Ahmed\n> CEO, Acme"
    #expect(SignalRules.signature(in: q, senderName: "Sara Ahmed") == nil)
    // Nothing worth keeping (no title, company, phone or link) is not a signature either.
    #expect(SignalRules.signature(in: "Regards\nsee you monday", senderName: nil) == nil)
}

@Test func aliasesNeedThreeOccurrences() {
    let three = """
    +966501234567: Sarita is in
    Ali: ok, Sarita will lead it
    +966501234567: thanks Sarita
    """
    #expect(SignalRules.aliases(in: three, names: ["Sara Ahmed"]) == ["Sarita"])

    let twice = """
    +966501234567: Sarita is in
    Ali: ok, Sarita will lead it
    """
    #expect(SignalRules.aliases(in: twice, names: ["Sara Ahmed"]).isEmpty)

    // The known name itself is never an alias, however often it occurs.
    let known = """
    @sara_ahmed: Sara Ahmed is in
    @sara_ahmed: Sara Ahmed will lead it
    @sara_ahmed: thanks Sara Ahmed
    """
    #expect(SignalRules.aliases(in: known, names: ["Sara Ahmed"]).isEmpty)

    // Far from any handle or name mention, a repeated capitalised word is not an alias.
    let far = String(repeating: "x", count: 60)
    let distant = "@sara_ahmed hello\n\(far) Sarita\n\(far) Sarita\n\(far) Sarita"
    #expect(SignalRules.aliases(in: distant, names: ["Sara Ahmed"]).isEmpty)
}

@Test func linksAreCanonical() {
    #expect(SignalRules.links(in: "see https://www.linkedin.com/in/Sara-Ahmed/?trk=1 and http://GitHub.com/sara")
        == ["https://linkedin.com/in/sara-ahmed", "https://github.com/sara"])
    // Deep paths are pages, not identities; duplicates collapse.
    #expect(SignalRules.links(in: "https://acme.com/team/sara https://acme.com/blog/2026/09/hiring https://ACME.com/team/sara")
        == ["https://acme.com/team/sara"])
}
