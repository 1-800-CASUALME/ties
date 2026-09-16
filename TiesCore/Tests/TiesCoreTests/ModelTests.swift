import Testing
import Foundation
@testable import TiesCore

@Test func personDisplayNameDefaults() {
    let p = Person(givenName: "Sara", familyName: "Ahmed")
    #expect(p.displayName == "Sara Ahmed")
    let org = Person(givenName: "", familyName: "", organization: "Acme")
    #expect(org.displayName == "Acme")
}

@Test func profileFactsSearchableTextAndEmpty() {
    #expect(ProfileFacts.empty.isEmpty)
    let f = ProfileFacts(occupation: "Engineer", companies: [Fact(text: "Acme")], canHelpWith: ["hiring"])
    #expect(!f.isEmpty)
    #expect(f.searchableText.contains("Engineer"))
    #expect(f.searchableText.contains("Acme"))
    #expect(f.searchableText.contains("hiring"))
}

@Test func profileFactsRoundTripsJSON() throws {
    let f = ProfileFacts(occupation: "CTO", summary: "Builds things.", achievements: [Fact(text: "Won X", sources: ["s1"])])
    let data = try JSONEncoder().encode(f)
    let back = try JSONDecoder().decode(ProfileFacts.self, from: data)
    #expect(back == f)
}
