import Foundation
import Testing
@testable import TiesCore

@Test func collectsSignatureFromOwnMail() async throws {
    let root = try EMLXFixture.mailbox()
    defer { try? FileManager.default.removeItem(at: root) }

    let collector = MailCollector(index: DirectoryMailIndex(root: root), root: root)
    #expect(collector.status() == .ready)
    let signals = try await collector.collect(
        for: input(name: ("Sara", "Ahmed"), emails: [EMLXFixture.person]),
        since: nil
    )

    #expect(signals.titles == ["Senior Product Manager"])
    #expect(signals.companies == ["Acme Corp"])
    #expect(signals.phones == ["+966501234567"])
    #expect(signals.links == ["https://linkedin.com/in/sara-ahmed"])
    // The From display name is RFC 2047 encoded and is not the Contacts name.
    #expect(signals.aliases == ["Sarita"])
    #expect(signals.sources == ["mail"])
    // Every message counts, in either direction; the newest is the quoted reply.
    #expect(signals.interactions == 3)
    #expect(signals.lastContact == Date(timeIntervalSince1970: 1_788_325_200))

    // The user's own signature, in the mail *to* the person, contributes nothing.
    #expect(!signals.companies.contains("Ties"))
    #expect(!signals.titles.contains("Founder"))
    #expect(!signals.links.contains { $0.contains("github.com/asim") })

    // Subjects are never stored, so nothing collected mentions one.
    let collected = signals.aliases + signals.titles + signals.companies + signals.links
    #expect(!collected.contains { $0.localizedCaseInsensitiveContains("call") })
}

@Test func ignoresQuotedReplies() async throws {
    let root = try EMLXFixture.temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try EMLXFixture.write(EMLXFixture.quotedReplyOnly, named: "1.emlx", in: root)

    let collector = MailCollector(index: DirectoryMailIndex(root: root), root: root)
    let signals = try await collector.collect(
        for: input(name: ("Sara", "Ahmed"), emails: [EMLXFixture.person]),
        since: nil
    )

    // The quoted block holds a title, a company, a phone and a link — none of them hers.
    #expect(signals.titles.isEmpty)
    #expect(signals.companies.isEmpty)
    #expect(signals.phones.isEmpty)
    #expect(signals.links.isEmpty)
    // The From display name is a header, not quoted text, so it still counts.
    #expect(signals.aliases == ["Sarita"])
    // It is still contact: the date and the count are read from it.
    #expect(signals.interactions == 1)
    #expect(signals.lastContact != nil)
}

@Test func respectsFiftyCap() async throws {
    let root = try EMLXFixture.mailbox(messageCount: 60)
    defer { try? FileManager.default.removeItem(at: root) }

    let collector = MailCollector(index: DirectoryMailIndex(root: root), root: root)
    let signals = try await collector.collect(
        for: input(name: ("Sara", "Ahmed"), emails: [EMLXFixture.person]),
        since: nil
    )

    #expect(collector.lastVisited == 50)
    #expect(signals.interactions == 50)
}

@Test func emlxParsesQuotedPrintableAndHTML() throws {
    let subject = Data("مرحبا".utf8).base64EncodedString()
    let quotedPrintable = """
        From: =?UTF-8?Q?Sara_Ahmed?= <\(EMLXFixture.person)>
        To: Asim <\(EMLXFixture.user)>
        Subject: =?UTF-8?B?\(subject)?=
        Date: Tue, 1 Sep 2026 10:00:00 +0300
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: quoted-printable

        Salut, we met at the caf=C3=A9 in Riyadh =
        yesterday.
        """
    let plain = try EMLX.parse(EMLXFixture.container(quotedPrintable))
    #expect(plain.from?.name == "Sara Ahmed")
    #expect(plain.from?.address == EMLXFixture.person)
    #expect(plain.subject == "مرحبا")
    #expect(plain.textBody.contains("café"))
    // The soft line break joins the two lines.
    #expect(plain.textBody.contains("Riyadh yesterday."))

    let html = """
        <html><body><div>Thanks for the call.</div><div><br></div>\
        <div>Best,<br>Sara Ahmed<br>Senior Product Manager | Acme Corp<br>\
        <a href="https://www.linkedin.com/in/sara-ahmed/">LinkedIn</a></div></body></html>
        """
    let multipart = """
        From: Sara Ahmed <\(EMLXFixture.person)>
        To: Asim <\(EMLXFixture.user)>
        Subject: Re: the call
        Date: Tue, 1 Sep 2026 10:00:00 +0300
        Content-Type: multipart/alternative;
         boundary="Apple-Mail-42"

        --Apple-Mail-42
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64

        \(Data(html.utf8).base64EncodedString())

        --Apple-Mail-42--
        """
    let stripped = try EMLX.parse(EMLXFixture.container(multipart))
    #expect(!stripped.textBody.contains("<div>"))
    // The block layout survives as line breaks, which is what the signature rules read.
    let signature = try #require(SignalRules.signature(in: stripped.textBody, senderName: "Sara Ahmed"))
    #expect(signature.titles == ["Senior Product Manager"])
    #expect(signature.companies == ["Acme Corp"])
    #expect(signature.links == ["https://linkedin.com/in/sara-ahmed"])
}

@Test func parsesPaddedByteCountFoldedHeadersAndRecipients() throws {
    let message = """
        From: Sara Ahmed <\(EMLXFixture.person)>
        To: Asim <\(EMLXFixture.user)>,
         Nada <nada@example.com>
        Cc: team@acme.com
        Subject: Re: the
         call
        Date: 1 Sep 2026 10:00:00 +0300

        Body text.
        """
    let parsed = try EMLX.parse(EMLXFixture.container(message, countPadding: 6))

    #expect(parsed.to == [EMLXFixture.user, "nada@example.com", "team@acme.com"])
    #expect(parsed.subject == "Re: the call")
    #expect(parsed.date == Date(timeIntervalSince1970: 1_788_246_000))
    #expect(parsed.textBody.trimmingCharacters(in: .whitespacesAndNewlines) == "Body text.")
    // The trailing plist is never part of the message.
    #expect(!parsed.textBody.contains("plist"))

    #expect(throws: SourceError.self) { try EMLX.parse(Data("no byte count here".utf8)) }
}

@Test func statusNeedsAccessWhenUnreadable() throws {
    let root = try EMLXFixture.temporaryRoot()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)

    #expect(MailCollector(index: DirectoryMailIndex(root: root), root: root).status() == .needsAccess)

    let missing = URL(fileURLWithPath: "/nonexistent/Library/Mail")
    #expect(MailCollector(index: DirectoryMailIndex(root: missing), root: missing).status() == .unavailable)
}

@Test func spotlightFallsBackToTheDirectoryWhenItFindsNothing() async throws {
    let root = try EMLXFixture.mailbox()
    defer { try? FileManager.default.removeItem(at: root) }

    // A temp directory is not indexed, so the query times out empty and the directory walk answers.
    let index = SpotlightMailIndex(root: root, timeout: 0.2)
    let urls = try await index.messageURLs(involving: EMLXFixture.person, limit: 50)

    #expect(urls.count == 3)
    #expect(urls.first?.lastPathComponent == "3.emlx")
}
