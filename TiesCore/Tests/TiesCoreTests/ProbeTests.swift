import Testing
import Foundation
@testable import TiesCore

@Test func gravatarFindingCarriesIdentityEvidence() async throws {
    let http = FakeHTTP(); http.routes = [("api.gravatar.com/v3/profiles/", 200, try fixture("gravatar", "json"))]
    let f = try await GravatarProbe().run(input(name: ("Beau", "Lebens"), emails: ["beau@automattic.com"]), client: http)
    #expect(f.count == 1)
    #expect(f[0].company == "Automattic")
    #expect(f[0].headline == "Lead, WooCommerce")
    #expect(f[0].evidence.contains { $0.kind == .emailHash })
    #expect(f[0].linkedURLs.contains("https://github.com/beaulebens"))
    #expect(http.requested[0].hasSuffix("27205e5c51cb03f862138b22bcb5dc20f94a342e744ff6df1b8dc8af3c865109"))
}

@Test func gravatarMissingProfileIsEmptyNotError() async throws {
    let http = FakeHTTP(); http.routes = [("api.gravatar.com", 404, Data())]
    let f = try await GravatarProbe().run(input(name: ("A", "B"), emails: ["a@b.com"]), client: http)
    #expect(f.isEmpty)
}

@Test func githubProbeResolvesLoginThenProfile() async throws {
    let http = FakeHTTP()
    http.routes = [("search/commits", 200, try fixture("github-commits", "json")), ("users/torvalds", 200, try fixture("github-user", "json"))]
    let f = try await GitHubProbe().run(input(name: ("Linus", "Torvalds"), emails: ["torvalds@linux-foundation.org"]), client: http)
    #expect(f.first?.url == "https://github.com/torvalds")
    #expect(f.first?.company == "Linux Foundation")
    #expect(f.first?.username == "torvalds")
    #expect(f.first?.evidence.contains { $0.kind == .emailHash } == true)
}

@Test func githubProbeMergesEvidenceWhenBothPathsResolveSameLogin() async throws {
    let http = FakeHTTP()
    http.routes = [("search/commits", 200, try fixture("github-commits", "json")), ("users/torvalds", 200, try fixture("github-user", "json"))]
    let f = try await GitHubProbe().run(
        input(name: ("Linus", "Torvalds"), emails: ["torvalds@linux-foundation.org"], urls: ["https://github.com/torvalds"]),
        client: http
    )
    #expect(f.count == 1)
    #expect(f[0].evidence.contains { $0.kind == .username })
    #expect(f[0].evidence.contains { $0.kind == .emailHash })
}

@Test func wmnDatasetLoadsAndFilters() throws {
    let d = try WMNDataset.bundled()
    #expect(d.sites.count > 500)
    let pro = d.professionalSites()
    #expect(pro.count == 40)
    #expect(pro.first?.name == "GitHub")
    #expect(!pro.contains { $0.cat == "xx NSFW xx" })
}

@Test func usernameProbeVerifiesTitle() async throws {
    let site = WMNSite(name: "Dribbble", uriCheck: "https://dribbble.com/{account}", eCode: 200, eString: " | Dribbble", mString: "(404)</title>", mCode: 404, cat: "art")
    let http = FakeHTTP()
    http.routes = [("dribbble.com/sara.ahmed", 200, Data("<html><title>Sara Ahmed | Dribbble</title></html>".utf8)),
                   ("dribbble.com/saraahmed", 200, Data("<html><title>Someone Else | Dribbble</title></html>".utf8))]
    let f = try await UsernameProbe(dataset: WMNDataset(sites: [site])).run(input(name: ("Sara", "Ahmed"), emails: ["sara.ahmed@x.com"]), client: http)
    #expect(f.count == 1)
    #expect(f[0].url == "https://dribbble.com/sara.ahmed")
    #expect(f[0].username == "sara.ahmed")
    #expect(f[0].evidence.contains { $0.kind == .username })
}

@Test func usernameProbeAcceptsJSONHitWithNoTitleWhenBodyMatchesName() async throws {
    let site = WMNSite(name: "API Example", uriCheck: "https://api.example.com/users/{account}", eCode: 200, eString: "login", mString: nil, mCode: nil, cat: "tech")
    let http = FakeHTTP()
    http.routes = [("api.example.com/users/sara.ahmed", 200, Data(#"{"login":"sara.ahmed","name":"Sara Ahmed"}"#.utf8))]
    let f = try await UsernameProbe(dataset: WMNDataset(sites: [site])).run(input(name: ("Sara", "Ahmed"), emails: ["sara.ahmed@x.com"]), client: http)
    #expect(f.count == 1)
    #expect(f[0].username == "sara.ahmed")
}

@Test func usernameProbeRejectsJSONHitWithNoTitleWhenBodyNameDiffers() async throws {
    let site = WMNSite(name: "API Example", uriCheck: "https://api.example.com/users/{account}", eCode: 200, eString: "login", mString: nil, mCode: nil, cat: "tech")
    let http = FakeHTTP()
    http.routes = [("api.example.com/users/sara.ahmed", 200, Data(#"{"login":"sara.ahmed","name":"Someone Else"}"#.utf8))]
    let f = try await UsernameProbe(dataset: WMNDataset(sites: [site])).run(input(name: ("Sara", "Ahmed"), emails: ["sara.ahmed@x.com"]), client: http)
    #expect(f.isEmpty)
}

@Test func readableTextKeepsMainDropsNav() throws {
    let html = String(decoding: try fixture("page", "html"), as: UTF8.self)
    let r = try ReadableText.extract(html: html)
    #expect(r.title == "Sara Ahmed — Growth")
    #expect(r.text.contains("Head of Growth at Acme"))
    #expect(!r.text.contains("Home About"))
    #expect(!r.text.contains("var x"))
    #expect(!r.text.contains("Short."))
}

@Test func pageFetchSkipsLinkedInAndRequiresName() async throws {
    let http = FakeHTTP()
    http.routes = [("sara.dev", 200, try fixture("page", "html")), ("other.com", 200, Data("<main><p>Nothing about anyone in particular here at all today.</p></main>".utf8))]
    let f = try await PageFetchProbe().run(input(name: ("Sara", "Ahmed"), urls: ["https://sara.dev", "https://www.linkedin.com/in/sara", "https://other.com"]), client: http)
    #expect(f.count == 1)
    #expect(f[0].url == "https://sara.dev")
    #expect(f[0].bodyText?.contains("Acme") == true)
    #expect(!http.requested.contains { $0.contains("linkedin") })
}
