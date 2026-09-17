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

/// A `MailIndex` that never finds anything — Spotlight with no index for the mailbox.
private struct EmptyMailIndex: MailIndex {
    func messageURLs(involving address: String, limit: Int) async throws -> [URL] { [] }
}

@Test func anUnindexedMailboxTooLargeToWalkSaysSo() async throws {
    let root = try EMLXFixture.mailbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = input(name: ("Sara", "Ahmed"), emails: [EMLXFixture.person])

    // Three files in the mailbox, a ceiling of two: the directory walk is not affordable, so an
    // empty run means "we could not look", not "no mail with her".
    let tooLarge = MailCollector(index: EmptyMailIndex(), root: root, fallbackCeiling: 2)
    #expect(tooLarge.status() == .ready)
    let nothing = try await tooLarge.collect(for: probe, since: nil)
    #expect(nothing.isEmpty)
    #expect(tooLarge.status() == .error(MailCollector.indexMissingMessage))

    // Under the ceiling the walk would have answered, so an empty result is the plain truth and
    // the mailbox stays ready.
    let small = MailCollector(index: EmptyMailIndex(), root: root, fallbackCeiling: 5_000)
    _ = try await small.collect(for: probe, since: nil)
    #expect(small.status() == .ready)

    // A later run that does find mail clears the complaint.
    let working = MailCollector(index: DirectoryMailIndex(root: root), root: root, fallbackCeiling: 2)
    _ = try await working.collect(for: probe, since: nil)
    #expect(working.status() == .ready)
}

@Test func theUnindexedVerdictIsTheRunsNotThePersons() async throws {
    let root = try EMLXFixture.mailbox()
    defer { try? FileManager.default.removeItem(at: root) }
    let collector = MailCollector(index: EmptyMailIndex(), root: root, fallbackCeiling: 2)

    try await collector.beginSession()
    _ = try await collector.collect(for: input(name: ("Sara", "Ahmed"), emails: [EMLXFixture.person]), since: nil)
    #expect(collector.status() == .error(MailCollector.indexMissingMessage))

    // Another person of the same run finishes afterwards. The mailbox is no more readable than
    // it was, so nothing they do may erase what the run already concluded — at concurrency 3 the
    // three of them overlap, and a per-call reset would lose the verdict entirely.
    _ = try await collector.collect(for: input(name: ("No", "One")), since: nil)
    #expect(collector.status() == .error(MailCollector.indexMissingMessage))
    await collector.endSession()
    #expect(collector.status() == .error(MailCollector.indexMissingMessage))

    // The next run starts with a clean slate.
    try await collector.beginSession()
    #expect(collector.status() == .ready)
}

@Test func aSpotlightMissFallsBackToTheMailboxTheRunRead() async throws {
    let root = try EMLXFixture.mailbox()
    defer { try? FileManager.default.removeItem(at: root) }

    // A temp directory is not indexed, so the query times out empty — which is indistinguishable
    // from "she has no mail", and is why the run reads the mailbox for itself.
    let collector = MailCollector(index: SpotlightMailIndex(root: root, timeout: 0.2), root: root)
    try await collector.beginSession()
    let signals = try await collector.collect(
        for: input(name: ("Sara", "Ahmed"), emails: [EMLXFixture.person]),
        since: nil
    )

    #expect(signals.interactions == 3)
    #expect(signals.titles == ["Senior Product Manager"])
    #expect(collector.mailboxReads == 1)
}

@Test func theMailboxIsReadOncePerRunAndOnlyMatchingBodiesAreParsed() async throws {
    let (root, addresses) = try EMLXFixture.mailbox(people: 50, messagesEach: 2, strangers: 100)
    defer { try? FileManager.default.removeItem(at: root) }

    // Spotlight has nothing to say about any of them, which is the case the old code answered
    // with a whole mailbox walk-and-MIME-parse per person per address.
    let collector = MailCollector(index: EmptyMailIndex(), root: root)
    try await collector.beginSession()

    for (index, address) in addresses.enumerated() {
        let signals = try await collector.collect(
            for: input(name: ("P\(index)", "Example"), emails: [address]),
            since: nil
        )
        #expect(signals.sources == ["mail"])
        #expect(signals.interactions == 2)
    }

    // One walk for the whole run, covering every file in the mailbox...
    #expect(collector.mailboxReads == 1)
    #expect(collector.indexedFileCount == 200)
    // ...and the only bodies opened are the hundred that are actually theirs. The hundred
    // strangers' messages were decided on their headers; their attachments were never read.
    #expect(collector.lastVisited == 100)
}

@Test func theDirectoryIndexDecidesOnHeadersAndOrdersNewestFirst() async throws {
    let root = try EMLXFixture.mailbox()
    defer { try? FileManager.default.removeItem(at: root) }

    // A message whose body is an attachment nothing can read still indexes: only its `From`,
    // `To`/`Cc` and `Date` are looked at.
    let messages = root.appendingPathComponent("V10/INBOX.mbox/Messages", isDirectory: true)
    try EMLXFixture.write("""
        From: Sara Ahmed <\(EMLXFixture.person)>
        To: Asim <\(EMLXFixture.user)>
        Subject: Scan
        Date: Thu, 3 Sep 2026 08:00:00 +0300
        Content-Type: application/octet-stream
        Content-Transfer-Encoding: base64

        \(String(repeating: "%%%\u{0}\u{1}", count: 100))
        """, named: "4.emlx", in: messages)

    let index = DirectoryMailIndex(root: root)
    let urls = try await index.messageURLs(involving: EMLXFixture.person, limit: 50)
    #expect(urls.count == 4)
    #expect(urls.first?.lastPathComponent == "4.emlx")

    // The limit is applied to the index, so it is the newest messages that are kept — and the
    // ones dropped are never opened again.
    let capped = try await index.messageURLs(involving: EMLXFixture.person, limit: 2)
    #expect(capped.map(\.lastPathComponent) == ["4.emlx", "3.emlx"])

    // Cc counts as involvement, and an address nobody wrote to has no messages at all.
    #expect(try await index.messageURLs(involving: "nobody@example.com", limit: 50).isEmpty)
}
