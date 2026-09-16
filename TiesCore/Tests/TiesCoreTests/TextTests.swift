import Testing
@testable import TiesCore

@Test func phoneNormalization() {
    #expect(PhoneNormalizer.e164("(555) 010-0100", defaultRegion: "US") == "+15550100100")
    #expect(PhoneNormalizer.e164("050 123 4567", defaultRegion: "SA") == "+966501234567")
    #expect(PhoneNormalizer.e164("hello", defaultRegion: "US") == nil)
    #expect(PhoneNormalizer.digits("+1 (555) 010") == "1555010")
}

@Test func nameSimilarity() {
    #expect(NameMatcher.similarity(personName: "Sara Ahmed", candidateName: "Sara Ahmed") == 1)
    #expect(NameMatcher.similarity(personName: "Robert Smith", candidateName: "Bob Smith") >= NameMatcher.gate)
    #expect(NameMatcher.similarity(personName: "Zoë Ali", candidateName: "Zoe Ali") >= NameMatcher.gate)
    #expect(NameMatcher.similarity(personName: "Sara Ahmed", candidateName: "Ahmed Sara") >= NameMatcher.gate)
    #expect(NameMatcher.similarity(personName: "Sara Ahmed", candidateName: "John Doe") < 0.6)
    #expect(NameMatcher.containsName("About Sara Ahmed, growth lead", personName: "Sara Ahmed"))
    #expect(!NameMatcher.containsName("About Sara, growth lead", personName: "Sara Ahmed"))
}

@Test func nameSimilarityFixRound1() {
    // Token-set gate: applies only when EVERY significant person-name token is present in the
    // candidate's tokens, not just the last one.
    #expect(NameMatcher.similarity(personName: "Ahmed Ali", candidateName: "Ali Ahmed Khan") >= NameMatcher.gate)
    #expect(NameMatcher.similarity(personName: "Sara Ahmed", candidateName: "Ahmed Khan") < NameMatcher.gate)

    // "alex" is claimed by both "alexander" and "alexandra" in the nickname table; resolution
    // must be deterministic and applied to both names, so either full form still matches.
    #expect(NameMatcher.similarity(personName: "Alex Smith", candidateName: "Alexandra Smith") >= NameMatcher.gate)
    #expect(NameMatcher.similarity(personName: "Alex Smith", candidateName: "Alexander Smith") >= NameMatcher.gate)
}

@Test func usernameDerivation() {
    let u = UsernameDeriver.candidates(givenName: "Sara", familyName: "Ahmed",
        emails: ["sara.ahmed+news@acme.com", "info@acme.com"], urls: ["https://github.com/sahmed", "https://x.com/SaraA"])
    #expect(u.first == "sara.ahmed")
    #expect(u.contains("saraahmed"))
    #expect(u.contains("sahmed"))
    #expect(u.contains("saraa"))
    #expect(!u.contains("info"))
    #expect(u.count <= 8)
    #expect(Set(u).count == u.count)
}
