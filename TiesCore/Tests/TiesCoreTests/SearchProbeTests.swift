import Testing
import Foundation
@testable import TiesCore

@Test func queryBuilderOrder() {
    let i = input(name: ("Sara", "Ahmed"), company: "Acme")
    let q = SearchQueryBuilder.queries(for: i)
    #expect(q[0] == "\"Sara Ahmed\" \"Acme\"")
    #expect(q[1] == "\"Sara Ahmed\" site:linkedin.com/in")
    #expect(!q.contains("\"Sara Ahmed\""))
    #expect(SearchQueryBuilder.queries(for: input(name: ("Cher", ""))).isEmpty)
}

@Test func linkedInSnippetParsing() {
    let a = LinkedInSnippet.parse(title: "Tim Cook - President of Single Cup Coffee | LinkedIn",
        snippet: "President of Single Cup Coffee · Experience: Single Cup Coffee · Location: Ottawa · 459 connections on LinkedIn.")
    #expect(a.name == "Tim Cook"); #expect(a.headline == "President of Single Cup Coffee")
    #expect(a.company == "Single Cup Coffee"); #expect(a.location == "Ottawa")
    let b = LinkedInSnippet.parse(title: "Tim Cook - London Area, United Kingdom - LinkedIn", snippet: "Location: London Area, United Kingdom · 500+ connections")
    #expect(b.headline == nil); #expect(b.location == "London Area, United Kingdom")
    let c = LinkedInSnippet.parse(title: "Tim Cook - Reinsurance Group of America, Incorporated | LinkedIn", snippet: "Experience: Reinsurance Group of America, Incorporated · Education: The Ohio State University · Location: League City")
    #expect(c.company == "Reinsurance Group of America, Incorporated")
}

struct FakeBackend: SearchBackend {
    let id = "fake"; var hits: [String: [SearchHit]]
    func search(_ query: String) async throws -> [SearchHit] { hits[query] ?? [] }
}

@Test func searchProbeBuildsLinkedInAndGitHubFindings() async throws {
    let backend = FakeBackend(hits: [
        "\"Sara Ahmed\" \"Acme\"": [SearchHit(url: "https://www.linkedin.com/in/sara-ahmed-1", title: "Sara Ahmed - Head of Growth | LinkedIn", snippet: "Head of Growth · Experience: Acme · Location: Riyadh")],
        "\"Sara Ahmed\" site:github.com": [SearchHit(url: "https://github.com/sahmed", title: "sahmed (Sara Ahmed) · GitHub", snippet: "Sara Ahmed has 12 repositories"),
                                            SearchHit(url: "https://github.com/unrelated", title: "unrelated (Bob) · GitHub", snippet: "nothing")],
    ])
    let f = try await SearchProbe(backend: backend).run(input(name: ("Sara", "Ahmed"), company: "Acme"), client: FakeHTTP())
    let li = f.first { $0.url.contains("linkedin") }!
    #expect(li.headline == "Head of Growth"); #expect(li.company == "Acme"); #expect(li.location == "Riyadh")
    #expect(li.evidence.contains { $0.kind == .company && $0.weight == 3 })
    #expect(li.bodyText == nil)
    let gh = f.first { $0.url == "https://github.com/sahmed" }!
    #expect(gh.username == "sahmed")
    #expect(!f.contains { $0.url.contains("unrelated") })
}

@Test func tavilyDecodes() async throws {
    let http = FakeHTTP()
    http.routes = [("api.tavily.com", 200, Data(#"{"results":[{"url":"https://a.com","title":"A","content":"c"}]}"#.utf8))]
    let hits = try await TavilySearchBackend(apiKey: "k", client: http).search("x")
    #expect(hits == [SearchHit(url: "https://a.com", title: "A", snippet: "c")])
}

@Test func searchProbeTreatsCountrySubdomainAsLinkedInProfile() async throws {
    let backend = FakeBackend(hits: [
        "\"Tim Cook\" site:linkedin.com/in": [SearchHit(
            url: "https://ca.linkedin.com/in/tim-cook-7387352b",
            title: "Tim Cook - President of Single Cup Coffee | LinkedIn",
            snippet: "President of Single Cup Coffee · Experience: Single Cup Coffee · Location: Ottawa"
        )],
    ])
    let f = try await SearchProbe(backend: backend).run(input(name: ("Tim", "Cook")), client: FakeHTTP())
    let li = f.first { $0.url.contains("ca.linkedin.com") }
    #expect(li != nil)
    #expect(li?.headline == "President of Single Cup Coffee")
    #expect(li?.company == "Single Cup Coffee")
    #expect(li?.location == "Ottawa")
    #expect(li?.bodyText == nil)
}

@Test func searchProbeAllowsNonLinkedInHitThroughOnCompanySubstringMatch() async throws {
    let backend = FakeBackend(hits: [
        "\"Sara Ahmed\" site:github.com": [
            SearchHit(url: "https://github.com/example", title: "jdoe · GitHub", snippet: "Senior engineer at Acme Corp working on backend systems"),
            SearchHit(url: "https://github.com/other", title: "asmith · GitHub", snippet: "Works at a totally different company"),
        ],
    ])
    let f = try await SearchProbe(backend: backend).run(input(name: ("Sara", "Ahmed"), company: "Acme Corp"), client: FakeHTTP())
    let matched = f.first { $0.url == "https://github.com/example" }
    #expect(matched != nil)
    #expect(matched?.evidence.contains { $0.kind == .company && $0.weight == 3 } == true)
    #expect(!f.contains { $0.url == "https://github.com/other" })
}
